# frozen_string_literal: true

module Denebola
  class Rope
    DEFAULT_CHUNK_SIZE = 1024
    LINE_BREAK = /\r\n|[\r\n\u2028\u2029]/

    class Chunk
      attr_reader :text, :summary, :line_ends
      def initialize(text)
        @text = text.frozen? ? text : text.dup.freeze
        @line_ends = []
        @summary = TextSummary.from_text(text, line_ends: @line_ends)
        @line_ends.freeze
        freeze
      end
    end

    attr_reader :tree, :chunk_size
    protected :tree

    def initialize(text = "", chunk_size: DEFAULT_CHUNK_SIZE, branching: Tree::DEFAULT_BRANCHING, tree: nil)
      raise ArgumentError, "chunk_size must be an integer >= 4" unless chunk_size.is_a?(Integer) && chunk_size >= 4
      @chunk_size = chunk_size
      @tree = tree || Tree.new(chunks(normalize_text(text)), summary: TextSummary, branching: branching)
      freeze
    end

    def summary = tree.summary
    def bytesize = summary.bytesize
    def length = summary.length
    alias size length
    def utf16_length = summary.utf16_length
    def line_count = summary.break_count + 1
    def empty? = bytesize.zero?

    def each_chunk
      return enum_for(__method__) unless block_given?
      tree.each { |chunk| yield chunk.text }
      self
    end

    def to_s
      text = String.new(capacity: bytesize, encoding: Encoding::UTF_8)
      each_chunk { |chunk| text << chunk }
      text
    end

    def insert(offset, text) = replace(offset...offset, text)
    def delete(range) = replace(range, "")

    def replace(range, text)
      start, finish = byte_bounds(range)
      replacement = normalize_text(text)
      first_index, first, prefix = locate_byte_offset(start)
      last_index, last, suffix = locate_byte_offset(finish)
      if first_index.positive? && start == prefix.bytesize
        first_index -= 1
        first = tree[first_index]
        prefix = tree.prefix_summary(first_index)
      end
      local_start = start - prefix.bytesize
      local_finish = finish - suffix.bytesize
      first ||= Chunk.new("")
      last ||= Chunk.new("")
      combined = first.text.byteslice(0, local_start) + replacement + last.text.byteslice(local_finish, last.text.bytesize - local_finish)
      values = chunks(combined)
      if first_index == last_index
        updated = tree.replace_at(first_index, values)
      else
        tail = last_index < tree.size ? last_index + 1 : tree.size
        updated = tree.slice(0, first_index).append(values).append(tree.slice(tail, tree.size - tail))
      end
      with_tree(updated)
    end

    # Ranges refer to the original snapshot. Adjacent edits are allowed; overlaps are rejected.
    def apply_edits(edits)
      normalized = edits.map { |range, text| [*byte_bounds(range), normalize_text(text)] }.sort_by { |start, finish, _| [start, finish] }
      previous = 0
      normalized.each do |start, finish, _|
        raise ArgumentError, "overlapping edits" if start < previous
        previous = finish
      end
      return self if normalized.empty?
      return replace(normalized[0][0]...normalized[0][1], normalized[0][2]) if normalized.length == 1
      # Split the remaining tree in order, so already consumed subtrees are never revisited.
      result = Tree.new(summary: TextSummary, branching: tree.branching)
      remaining = self
      consumed = 0
      normalized.each do |start, finish, text|
        left, rest = remaining.split_at(start - consumed)
        _, remaining = rest.split_at(finish - start)
        result = join_trees(result, left.tree)
        result = join_trees(result, Tree.new(chunks(text), summary: TextSummary, branching: tree.branching))
        consumed = finish
      end
      with_tree(join_trees(result, remaining.tree))
    end

    def byteslice(offset, length = nil)
      start, finish = offset.is_a?(Range) ? byte_bounds(offset) : byte_bounds(offset...(offset + (length || bytesize - offset)))
      return self if start.zero? && finish == bytesize
      first_index, first, prefix = locate_byte_offset(start)
      last_index, last, suffix = locate_byte_offset(finish)
      return with_tree(Tree.new(summary: TextSummary, branching: tree.branching)) if finish == start
      local_start = start - prefix.bytesize
      if first_index == last_index
        return with_tree(Tree.new([Chunk.new(first.text.byteslice(local_start, finish - start))], summary: TextSummary, branching: tree.branching))
      end
      middle_start = first_index + (local_start.positive? ? 1 : 0)
      result = tree.slice(middle_start, last_index - middle_start)
      if local_start.positive?
        head = Chunk.new(first.text.byteslice(local_start, first.text.bytesize - local_start))
        result = Tree.new([head], summary: TextSummary, branching: tree.branching).append(result)
      end
      local_finish = finish - suffix.bytesize
      result = result.push(Chunk.new(last.text.byteslice(0, local_finish))) if local_finish.positive?
      with_tree(result)
    end

    def split_at(offset)
      index, chunk, prefix = locate_byte_offset(offset)
      return [self, with_tree(Tree.new(summary: TextSummary, branching: tree.branching))] unless chunk
      left, right = tree.split_at(index)
      local = offset - prefix.bytesize
      if local.positive?
        left = left.push(Chunk.new(chunk.text.byteslice(0, local)))
        right = right.replace_at(0, [Chunk.new(chunk.text.byteslice(local, chunk.text.bytesize - local))])
      end
      [with_tree(left), with_tree(right)]
    end

    def line(row)
      _, chunk, prefix, local = line_location(row)
      return "" unless chunk
      next_end = chunk.line_ends.bsearch { |ending| ending > local }
      if next_end && !(chunk.text.getbyte(next_end - 1) == 13 && next_end == chunk.text.bytesize)
        return chunk.text.byteslice(local, next_end - local).sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "")
      end
      start = prefix.bytesize + local
      finish = row + 1 < line_count ? line_start(row + 1) : bytesize
      text = read_bytes(start, finish - start)
      text.sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "")
    end

    def line_start(row)
      _, _, prefix, local = line_location(row)
      prefix.bytesize + local
    end

    private def line_location(row)
      raise RangeError, "line out of bounds" unless row.is_a?(Integer) && row.between?(0, line_count - 1)
      return [0, tree[0], TextSummary.zero, 0] if row.zero?
      index, chunk, prefix = tree.locate(row, :break_count, bias: :left)
      local_row = row - prefix.break_count - 1
      local_row += 1 if prefix.ends_with_cr? && chunk.summary.starts_with_lf?
      local = chunk.line_ends.fetch(local_row)
      if local == chunk.text.bytesize
        previous = chunk.text.getbyte(local - 1)
        prefix += chunk.summary
        index += 1
        chunk = tree[index]
        local = previous == 13 && chunk&.text&.start_with?("\n") ? 1 : 0
      end
      [index, chunk, prefix, local]
    end

    # Columns count Unicode codepoints, not bytes, graphemes, or UTF-16 code units.
    def point_at(byte_offset)
      total = summary_before(byte_offset)
      Point.new(total.break_count, total.last_line_length)
    end

    def offset_at(point)
      _, chunk, prefix, local = line_location(point.row)
      start = prefix.bytesize + local
      ending = chunk&.line_ends&.bsearch { |finish| finish > local }
      text = ending ? chunk.text.byteslice(local, ending - local).sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "") : line(point.row)
      raise RangeError, "column out of bounds" unless point.column.between?(0, text.length)
      start + text[0, point.column].bytesize
    end

    def utf16_offset_at(byte_offset) = summary_before(byte_offset).utf16_length

    def offset_at_utf16(utf16_offset)
      raise RangeError, "UTF-16 offset out of bounds" unless utf16_offset.is_a?(Integer) && utf16_offset.between?(0, utf16_length)
      _, chunk, prefix = tree.locate(utf16_offset, :utf16_length)
      return bytesize unless chunk
      units = prefix.utf16_length
      bytes = prefix.bytesize
      chunk.text.each_codepoint do |codepoint|
        return bytes if units == utf16_offset
        units += codepoint > 0xffff ? 2 : 1
        bytes += codepoint.chr(Encoding::UTF_8).bytesize
        raise RangeError, "UTF-16 offset splits a surrogate pair" if units > utf16_offset
      end
      bytes
    end

    def utf16_point_at(byte_offset)
      point = point_at(byte_offset)
      column = utf16_offset_at(byte_offset) - utf16_offset_at(line_start(point.row))
      Point.new(point.row, [column, 0].max)
    end

    def offset_at_utf16_point(point)
      start = line_start(point.row)
      offset = offset_at_utf16(utf16_offset_at(start) + point.column)
      raise RangeError, "column out of bounds" if offset > start + line(point.row).bytesize
      offset
    end

    def anchor(byte_offset, bias: :right)
      locate_byte_offset(byte_offset)
      Anchor.new(byte_offset, bias: bias)
    end

    def check_invariants!
      tree.check_invariants!
      each_chunk { |text| raise "invalid UTF-8 chunk" unless text.valid_encoding? && text.frozen? }
      raise "incorrect text summary" unless summary == TextSummary.from_text(to_s)
      true
    end

    private

    def with_tree(tree) = self.class.new(chunk_size: chunk_size, tree: tree)

    def join_trees(left, right)
      return right if left.empty?
      return left if right.empty?
      boundary = chunks(left[left.size - 1].text + right[0].text)
      left.slice(0, left.size - 1).append(boundary).append(right.slice(1, right.size - 1))
    end

    def normalize_text(text)
      raise TypeError, "text must be a String" unless text.is_a?(String)
      string = text.encoding == Encoding::UTF_8 ? text : text.encode(Encoding::UTF_8)
      raise ArgumentError, "text must be valid UTF-8" unless string.valid_encoding?
      string
    end

    def chunks(text)
      return [] if text.empty?
      return [Chunk.new(text)] if text.bytesize <= chunk_size
      result = []
      if text.ascii_only?
        offset = 0
        while offset < text.bytesize
          length = [chunk_size, text.bytesize - offset].min
          length -= 1 if text.getbyte(offset + length - 1) == 13 && text.getbyte(offset + length) == 10
          result << Chunk.new(text.byteslice(offset, length))
          offset += length
        end
      else
        buffer = +""
        text.each_grapheme_cluster do |grapheme|
          if !buffer.empty? && buffer.bytesize + grapheme.bytesize > chunk_size
            result << Chunk.new(buffer)
            buffer = +""
          end
          buffer << grapheme
        end
        result << Chunk.new(buffer) unless buffer.empty?
      end
      result
    end

    def byte_bounds(range)
      raise TypeError, "expected a Range of byte offsets" unless range.is_a?(Range)
      start = range.begin || 0
      finish = range.end.nil? ? bytesize : range.end + (range.exclude_end? ? 0 : 1)
      unless start.is_a?(Integer) && finish.is_a?(Integer) && start >= 0 && finish >= start && finish <= bytesize
        raise RangeError, "byte range out of bounds"
      end
      [start, finish]
    end

    def locate_byte_offset(offset)
      raise RangeError, "byte offset out of bounds" unless offset.is_a?(Integer) && offset.between?(0, bytesize)
      result = tree.locate(offset, :bytesize)
      chunk = result[1]
      byte = chunk&.text&.getbyte(offset - result[2].bytesize)
      raise RangeError, "byte offset splits a UTF-8 character" if byte && (byte & 0xc0) == 0x80
      result
    end

    def summary_before(offset)
      _, chunk, prefix = locate_byte_offset(offset)
      chunk ? prefix + TextSummary.from_text(chunk.text.byteslice(0, offset - prefix.bytesize)) : prefix
    end

    def read_bytes(offset, length)
      return "" if length.zero?
      index, chunk, prefix = locate_byte_offset(offset)
      local = offset - prefix.bytesize
      return chunk.text.byteslice(local, length) if local + length <= chunk.text.bytesize
      text = String.new(capacity: length, encoding: Encoding::UTF_8)
      while chunk && text.bytesize < length
        text << chunk.text.byteslice(local, [length - text.bytesize, chunk.text.bytesize - local].min)
        local = 0
        index += 1
        chunk = tree[index]
      end
      text
    end
  end
end
