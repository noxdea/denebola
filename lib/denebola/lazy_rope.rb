# frozen_string_literal: true

module Denebola
  # A file-backed text rope. File pages and indexes are populated on demand;
  # edits replace only the affected byte ranges with ordinary Rope values.
  class LazyRope
    DEFAULT_CHUNK_SIZE = 1_048_576
    DEFAULT_CACHE_CHUNKS = 8
    FilePiece = Struct.new(:offset, :bytesize, keyword_init: true)
    TextPiece = Struct.new(:rope, keyword_init: true) do
      def bytesize = rope.bytesize
    end
    class FileOwner
      def initialize(file)
        @file = file
        @lock = Mutex.new
      end

      def closed? = @file.closed?

      def close
        @lock.synchronize { @file.close unless @file.closed? }
        nil
      end
    end
    private_constant :FileOwner

    attr_reader :chunk_size, :cached_bytes

    def self.open(path, chunk_size: DEFAULT_CHUNK_SIZE, encoding: Encoding::UTF_8, cache_chunks: DEFAULT_CACHE_CHUNKS)
      new(path, chunk_size: chunk_size, encoding: encoding, cache_chunks: cache_chunks)
    end

    def initialize(path, chunk_size: DEFAULT_CHUNK_SIZE, encoding: Encoding::UTF_8, cache_chunks: DEFAULT_CACHE_CHUNKS)
      raise ArgumentError, "chunk_size must be an integer >= 4" unless chunk_size.is_a?(Integer) && chunk_size >= 4
      raise ArgumentError, "cache_chunks must be a positive integer" unless cache_chunks.is_a?(Integer) && cache_chunks.positive?
      raise ArgumentError, "only UTF-8 files are supported" unless encoding == Encoding::UTF_8

      flags = File::RDONLY | File::BINARY
      flags |= File::SHARE_DELETE if defined?(File::SHARE_DELETE)
      @file = File.open(path, flags)
      @file_owner = FileOwner.new(@file)
      @path = File.expand_path(path)
      @chunk_size = chunk_size
      @cache_chunks = cache_chunks
      @cache = {}
      @cached_bytes = 0
      @positioned_reads = true
      @read_lock = Mutex.new
      @stamp = file_stamp(@file.stat)
      @path_stamp = file_stamp(File.stat(@path))
      @origin = @file.size >= 3 && raw_read(0, 3) == "\xEF\xBB\xBF".b ? 3 : 0
      @source_bytesize = @file.size - @origin
      @pieces = @source_bytesize.zero? ? [] : [FilePiece.new(offset: 0, bytesize: @source_bytesize).freeze]
      rebuild_piece_ends
      reset_index
    rescue StandardError
      @file&.close
      raise
    end

    def lazy? = true
    def closed? = @file_owner.closed?

    def bytesize
      ensure_unchanged!
      @piece_ends.last || 0
    end
    def empty? = bytesize.zero?

    def length
      index_to_eof
      @indexed_characters
    end

    def size = length

    def utf16_length
      index_to_eof
      @indexed_utf16
    end

    # Until exact indexing is requested, return an estimate based on the
    # already scanned prefix. The estimate never reports fewer known lines.
    def line_count(exact: false)
      index_to_eof if exact
      return packed_line_count if @index_complete
      scan_index if @indexed_offset.zero? && bytesize.positive?

      known_lines = packed_line_count + (@pending_cr ? 1 : 0)
      breaks = known_lines - 1
      return 1 if breaks.zero? || @indexed_offset.zero?

      [known_lines, (breaks * bytesize.fdiv(@indexed_offset)).round + 1].max
    end

    def line_start(row)
      raise RangeError, "line out of bounds" unless row.is_a?(Integer) && row >= 0
      index_until_line(row)
      raise RangeError, "line out of bounds" if row >= packed_line_count

      unpack_line_start(row)
    end

    def line(row)
      start = line_start(row)
      index_until_line(row + 1)
      ending = row + 1 < packed_line_count ? unpack_line_start(row + 1) : bytesize
      read_bytes(start, ending - start).force_encoding(Encoding::UTF_8).sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "")
    end

    def line_end(row)
      start = line_start(row)
      index_until_line(row + 1)
      ending = row + 1 < packed_line_count ? unpack_line_start(row + 1) : bytesize
      tail = read_bytes([ending - 3, start].max, [ending - start, 3].min)
      ending - (tail.end_with?("\r\n") ? 2 : tail.end_with?("\xE2\x80\xA8".b, "\xE2\x80\xA9".b) ? 3 : tail.end_with?("\r", "\n") ? 1 : 0)
    end

    def line_window(row, from: 0, max_bytes: 16_384)
      raise TypeError, "from must be an Integer" unless from.is_a?(Integer)
      raise ArgumentError, "max_bytes must be a nonnegative integer" unless max_bytes.is_a?(Integer) && max_bytes >= 0

      start, ending = line_start(row), line_end(row)
      offset = (start + from).clamp(start, ending)
      offset -= 1 while offset > start && offset < ending && (read_bytes(offset, 1).getbyte(0) & 0xC0) == 0x80
      value = read_bytes(offset, [max_bytes, ending - offset].min)
      value = value.byteslice(0, complete_utf8_length(value)) unless value.empty?
      [value.force_encoding(Encoding::UTF_8), offset - start]
    end

    def byteslice(offset, length = nil)
      start, finish = slice_bounds(offset, length)
      Rope.new(read_bytes(start, finish - start).force_encoding(Encoding::UTF_8))
    end

    def each_chunk
      return enum_for(__method__) unless block_given?

      offset = 0
      total = bytesize
      while offset < total
        raw = read_bytes(offset, [chunk_size, total - offset].min)
        complete = complete_utf8_length(raw)
        if complete.zero?
          raw = read_bytes(offset, [chunk_size + 3, total - offset].min)
          complete = complete_utf8_length(raw)
        end
        text = raw.byteslice(0, complete).force_encoding(Encoding::UTF_8)
        raise Error, "file contains invalid UTF-8" if complete.zero? || !text.valid_encoding?
        yield text
        offset += complete
      end
      self
    end

    def materialize(range = nil)
      range ? byteslice(range) : Rope.new(to_s)
    end

    def to_s
      text = String.new(capacity: bytesize, encoding: Encoding::UTF_8)
      each_chunk { |chunk| text << chunk }
      text
    end

    # Mutates this file-backed view and keeps untouched ranges file-backed.
    def edit(range, text)
      replacement = normalize_text(text)
      start, finish = byte_bounds(range)
      validate_offset(start)
      validate_offset(finish)

      updated = pieces_for(0, start)
      updated << TextPiece.new(rope: Rope.new(replacement)).freeze unless replacement.empty?
      updated.concat(pieces_for(finish, bytesize))
      @pieces = coalesce(updated)
      rebuild_piece_ends
      invalidate_index_from(start)
      self
    end

    def insert(offset, text) = edit(offset...offset, text)
    def delete(range) = edit(range, "")
    def replace(range, text) = edit(range, text)

    # Ranges address the original snapshot. The returned view has independent
    # overlays, indexes, and cache. Snapshots share one backing-file lifetime:
    # closing any snapshot closes the complete family.
    def apply_edits(edits)
      normalized = Edit.sort(edits.map do |range, text|
        start, finish = byte_bounds(range)
        validate_offset(start)
        validate_offset(finish)
        [start, finish, normalize_text(text)]
      end)
      previous = 0
      normalized.each do |start, finish, _text|
        raise ArgumentError, "overlapping edits" if start < previous
        previous = finish
      end
      return self if normalized.empty?

      updated = []
      consumed = 0
      normalized.each do |start, finish, text|
        updated.concat(pieces_for(consumed, start))
        updated << TextPiece.new(rope: Rope.new(text)).freeze unless text.empty?
        consumed = finish
      end
      updated.concat(pieces_for(consumed, bytesize))
      snapshot_with(coalesce(updated))
    end

    def point_at(byte_offset)
      validate_offset(byte_offset)
      index_to([byte_offset + 1, bytesize].min)
      if byte_offset.positive? && byte_offset < bytesize && read_bytes(byte_offset - 1, 2) == "\r\n"
        row = line_index_at(byte_offset + 1)
        return Point.new(row, 0)
      end

      row = line_index_at(byte_offset)
      start = unpack_line_start(row)
      Point.new(row, read_bytes(start, byte_offset - start).force_encoding(Encoding::UTF_8).length)
    end

    def offset_at(point)
      start = line_start(point.row)
      content = line(point.row)
      raise RangeError, "column out of bounds" unless point.column.is_a?(Integer) && point.column.between?(0, content.length)

      start + content.each_char.take(point.column).join.bytesize
    end

    def utf16_offset_at(byte_offset)
      validate_offset(byte_offset)
      prefix_dimensions(byte_offset).last
    end

    def offset_at_utf16(utf16_offset)
      raise RangeError, "UTF-16 offset out of bounds" unless utf16_offset.is_a?(Integer) && utf16_offset >= 0
      index_to_eof
      raise RangeError, "UTF-16 offset out of bounds" if utf16_offset > @indexed_utf16

      checkpoint = @checkpoints.bsearch { |entry| entry[2] > utf16_offset }
      checkpoint = checkpoint ? @checkpoints[@checkpoints.index(checkpoint) - 1] : @checkpoints.last
      offset, _characters, units = checkpoint
      return offset if units == utf16_offset

      each_codepoint_from(offset) do |codepoint, byte_start, _byte_finish|
        width = codepoint > 0xFFFF ? 2 : 1
        raise RangeError, "UTF-16 offset splits a surrogate pair" if units + width > utf16_offset
        units += width
        return _byte_finish if units == utf16_offset
        break if units > utf16_offset
      end
      raise RangeError, "UTF-16 offset out of bounds"
    end

    def utf16_point_at(byte_offset)
      point = point_at(byte_offset)
      start = line_start(point.row)
      Point.new(point.row, [utf16_offset_at(byte_offset) - utf16_offset_at(start), 0].max)
    end

    def offset_at_utf16_point(point)
      start = line_start(point.row)
      content = line(point.row)
      units = 0
      bytes = 0
      content.each_codepoint do |codepoint|
        return start + bytes if units == point.column
        width = codepoint > 0xFFFF ? 2 : 1
        raise RangeError, "UTF-16 column splits a surrogate pair" if units + width > point.column
        units += width
        bytes += codepoint.chr(Encoding::UTF_8).bytesize
      end
      return start + bytes if units == point.column

      raise RangeError, "column out of bounds"
    end

    def anchor(byte_offset, bias: :right)
      validate_offset(byte_offset)
      Anchor.new(byte_offset, bias: bias)
    end

    def check_invariants!
      ensure_unchanged!
      raise Error, "invalid piece index" unless @piece_ends.each_cons(2).all? { |left, right| left < right }
      raise Error, "invalid piece size" unless @pieces.all? { |piece| piece.bytesize.positive? }
      @pieces.grep(TextPiece).each { |piece| piece.rope.check_invariants! }
      index_to_eof
      starts = @line_starts.unpack("Q<*")
      raise Error, "invalid line index" unless starts.first == 0 && starts.each_cons(2).all? { |left, right| left < right } && starts.last <= bytesize
      raise Error, "invalid dimension index" unless @checkpoints.each_cons(2).all? { |left, right| left[0] < right[0] }
      true
    end

    def close
      @file_owner.close
    end

    private

    def normalize_text(text)
      raise TypeError, "text must be a String" unless text.is_a?(String)
      value = text.encoding == Encoding::UTF_8 ? text.dup : text.encode(Encoding::UTF_8)
      raise ArgumentError, "text must be valid UTF-8" unless value.valid_encoding?
      value
    end

    def byte_bounds(range)
      raise TypeError, "range must be a Range" unless range.is_a?(Range)
      start = range.begin || 0
      finish = range.end || bytesize
      finish += 1 unless range.exclude_end? || range.end.nil?
      raise RangeError, "range out of bounds" unless start.is_a?(Integer) && finish.is_a?(Integer) && start.between?(0, bytesize) && finish.between?(start, bytesize)
      [start, finish]
    end

    def slice_bounds(offset, length)
      return byte_bounds(offset) if offset.is_a?(Range)
      raise TypeError, "offset must be an Integer" unless offset.is_a?(Integer)
      length ||= bytesize - offset
      raise RangeError, "slice out of bounds" unless length.is_a?(Integer) && length >= 0 && offset.between?(0, bytesize) && offset + length <= bytesize
      validate_offset(offset)
      validate_offset(offset + length)
      [offset, offset + length]
    end

    def validate_offset(offset)
      raise RangeError, "offset out of bounds" unless offset.is_a?(Integer) && offset.between?(0, bytesize)
      return if offset == bytesize || (read_bytes(offset, 1).getbyte(0) & 0xC0) != 0x80
      raise RangeError, "offset inside UTF-8 character"
    end

    def pieces_for(start, finish)
      return [] if start == finish
      result = []
      piece_start = 0
      @pieces.each do |piece|
        piece_finish = piece_start + piece.bytesize
        overlap_start = [start, piece_start].max
        overlap_finish = [finish, piece_finish].min
        result << slice_piece(piece, overlap_start - piece_start, overlap_finish - overlap_start) if overlap_start < overlap_finish
        piece_start = piece_finish
      end
      result
    end

    def slice_piece(piece, local_start, length)
      if piece.is_a?(FilePiece)
        FilePiece.new(offset: piece.offset + local_start, bytesize: length).freeze
      else
        TextPiece.new(rope: piece.rope.byteslice(local_start, length)).freeze
      end
    end

    def coalesce(pieces)
      pieces.each_with_object([]) do |piece, result|
        previous = result.last
        if previous.is_a?(FilePiece) && piece.is_a?(FilePiece) && previous.offset + previous.bytesize == piece.offset
          result[-1] = FilePiece.new(offset: previous.offset, bytesize: previous.bytesize + piece.bytesize).freeze
        elsif previous.is_a?(TextPiece) && piece.is_a?(TextPiece) && previous.bytesize + piece.bytesize <= Rope::DEFAULT_CHUNK_SIZE
          result[-1] = TextPiece.new(rope: Rope.new(previous.rope.to_s + piece.rope.to_s)).freeze
        else
          result << piece
        end
      end
    end

    def rebuild_piece_ends
      total = 0
      @piece_ends = @pieces.map { |piece| total += piece.bytesize }
    end

    def snapshot_with(pieces)
      ensure_unchanged!
      snapshot = dup
      snapshot.instance_variable_set(:@cache, {})
      snapshot.instance_variable_set(:@cached_bytes, 0)
      snapshot.instance_variable_set(:@pieces, pieces.freeze)
      snapshot.__send__(:rebuild_piece_ends)
      snapshot.__send__(:reset_index)
      snapshot
    end

    def read_bytes(offset, count)
      ensure_unchanged!
      return "".b if count.zero?
      raise RangeError, "read out of bounds" unless offset >= 0 && count >= 0 && offset + count <= (@piece_ends.last || 0)

      output = String.new(capacity: count, encoding: Encoding::BINARY)
      piece_index = @piece_ends.bsearch_index { |piece_end| piece_end > offset } || @pieces.length
      piece_start = piece_index.zero? ? 0 : @piece_ends[piece_index - 1]
      while piece_index < @pieces.length
        piece = @pieces[piece_index]
        piece_finish = piece_start + piece.bytesize
        if offset < piece_finish && offset + count > piece_start
          local_start = [offset - piece_start, 0].max
          length = [[offset + count, piece_finish].min - (piece_start + local_start), 0].max
          if piece.is_a?(FilePiece)
            output << read_file(piece.offset + local_start, length)
          else
            append_rope_bytes(output, piece.rope, local_start, length)
          end
        end
        break if output.bytesize == count
        piece_start = piece_finish
        piece_index += 1
      end
      raise Error, "short read" unless output.bytesize == count
      output
    end

    def append_rope_bytes(output, rope, offset, count)
      tree = rope.__send__(:tree)
      index, chunk, prefix = tree.locate(offset, :bytesize)
      local = offset - prefix.bytesize
      while chunk && count.positive?
        length = [count, chunk.text.bytesize - local].min
        output << chunk.text.b.byteslice(local, length)
        count -= length
        local = 0
        index += 1
        chunk = tree[index]
      end
    end

    def read_file(offset, count)
      output = String.new(capacity: count, encoding: Encoding::BINARY)
      while count.positive?
        page, local = offset.divmod(chunk_size)
        data = @cache.delete(page)
        unless data
          data = raw_read(@origin + page * chunk_size, [chunk_size, @source_bytesize - page * chunk_size].min)
          @cached_bytes += data.bytesize
          while @cache.length >= @cache_chunks
            _old_page, old_data = @cache.shift
            @cached_bytes -= old_data.bytesize
          end
        end
        @cache[page] = data
        length = [count, data.bytesize - local].min
        raise Error, "file was truncated" unless length.positive?
        output << data.byteslice(local, length)
        offset += length
        count -= length
      end
      output
    end

    def raw_read(offset, count)
      return "".b if count.zero?
      if @positioned_reads
        @file.pread(count, offset)
      else
        @read_lock.synchronize do
          @file.seek(offset)
          @file.read(count)
        end
      end
    rescue NotImplementedError
      @positioned_reads = false
      retry
    end

    def reset_index
      @line_starts = [0].pack("Q<")
      @indexed_offset = 0
      @indexed_characters = 0
      @indexed_utf16 = 0
      @pending_cr = nil
      @checkpoints = [[0, 0, 0, nil]]
      @index_complete = false
    end

    def invalidate_index_from(offset)
      # Re-scan the byte before an edit as well: inserting or removing an LF
      # can change whether a preceding CR is one terminator or half of CRLF.
      rewind_to = [offset - 1, 0].max
      checkpoint_index = @checkpoints.rindex { |entry| entry[0] <= rewind_to } || 0
      checkpoint = @checkpoints[checkpoint_index]
      @checkpoints = @checkpoints.take(checkpoint_index + 1)
      @indexed_offset, @indexed_characters, @indexed_utf16, @pending_cr = checkpoint
      starts = @line_starts.unpack("Q<*").take_while { |line_start| line_start <= @indexed_offset }
      @line_starts = starts.pack("Q<*")
      @index_complete = false
    end

    def index_until_line(row)
      scan_index while packed_line_count <= row && !@index_complete
    end

    def index_to(offset)
      scan_index while @indexed_offset < offset && !@index_complete
    end

    def index_to_eof
      scan_index until @index_complete
    end

    def scan_index
      total = bytesize
      if @indexed_offset == total
        append_line_start(@pending_cr) if @pending_cr
        @pending_cr = nil
        @index_complete = true
        @checkpoints[-1] = [@indexed_offset, @indexed_characters, @indexed_utf16, nil]
        return
      end

      raw = read_bytes(@indexed_offset, [chunk_size, total - @indexed_offset].min)
      complete = complete_utf8_length(raw)
      text = raw.byteslice(0, complete).force_encoding(Encoding::UTF_8)
      raise Error, "file contains invalid UTF-8" if complete.zero? || !text.valid_encoding?

      if text.ascii_only?
        scan_ascii_index(text)
      else
        scan_unicode_index(text)
      end
      @indexed_offset += complete
      @checkpoints << [@indexed_offset, @indexed_characters, @indexed_utf16, @pending_cr]
      scan_index if @indexed_offset == total
    end

    def append_line_start(offset)
      return if unpack_line_start(packed_line_count - 1) == offset
      @line_starts << [offset].pack("Q<")
    end

    def packed_line_count = @line_starts.bytesize / 8
    def unpack_line_start(row) = @line_starts.unpack1("Q<", offset: row * 8)

    def line_index_at(offset)
      low = 0
      high = packed_line_count
      while low < high
        middle = (low + high) / 2
        unpack_line_start(middle) <= offset ? low = middle + 1 : high = middle
      end
      [low - 1, 0].max
    end

    def prefix_dimensions(offset)
      index_to(offset)
      checkpoint_index = @checkpoints.bsearch_index { |entry| entry[0] > offset }
      checkpoint = checkpoint_index ? @checkpoints[checkpoint_index - 1] : @checkpoints.last
      base, characters, units = checkpoint
      text = read_bytes(base, offset - base).force_encoding(Encoding::UTF_8)
      raise RangeError, "offset inside UTF-8 character" unless text.valid_encoding?
      [characters + text.length, units + (text.ascii_only? ? text.bytesize : text.encode(Encoding::UTF_16LE).bytesize / 2)]
    end

    def each_codepoint_from(offset)
      while offset < bytesize
        raw = read_bytes(offset, [chunk_size, bytesize - offset].min)
        complete = complete_utf8_length(raw)
        text = raw.byteslice(0, complete).force_encoding(Encoding::UTF_8)
        raise Error, "file contains invalid UTF-8" if complete.zero? || !text.valid_encoding?
        cursor = offset
        text.each_codepoint do |codepoint|
          finish = cursor + codepoint.chr(Encoding::UTF_8).bytesize
          yield codepoint, cursor, finish
          cursor = finish
        end
        offset += complete
      end
    end

    def scan_ascii_index(text)
      base = @indexed_offset
      @indexed_characters += text.bytesize
      @indexed_utf16 += text.bytesize
      scan_from = 0
      if @pending_cr
        if text.start_with?("\n")
          append_line_start(base + 1)
          scan_from = 1
        else
          append_line_start(@pending_cr)
        end
        @pending_cr = nil
      end
      text.b.byteslice(scan_from, text.bytesize - scan_from).scan(/\r\n|[\r\n]/n) do |ending|
        finish = base + scan_from + Regexp.last_match.end(0)
        if ending == "\r" && finish == base + text.bytesize
          @pending_cr = finish
        else
          append_line_start(finish)
        end
      end
    end

    def scan_unicode_index(text)
      cursor = @indexed_offset
      text.each_codepoint do |codepoint|
        width = codepoint.chr(Encoding::UTF_8).bytesize
        finish = cursor + width
        @indexed_characters += 1
        @indexed_utf16 += codepoint > 0xFFFF ? 2 : 1
        if @pending_cr
          if codepoint == 10
            append_line_start(finish)
            @pending_cr = nil
            cursor = finish
            next
          end
          append_line_start(@pending_cr)
          @pending_cr = nil
        end
        if codepoint == 13
          @pending_cr = finish
        elsif codepoint == 10 || codepoint == 0x2028 || codepoint == 0x2029
          append_line_start(finish)
        end
        cursor = finish
      end
    end

    def complete_utf8_length(value)
      return 0 if value.empty?
      index = value.bytesize - 1
      index -= 1 while index.positive? && (value.getbyte(index) & 0xC0) == 0x80
      leading = value.getbyte(index)
      expected = leading < 0x80 ? 1 : leading < 0xE0 ? 2 : leading < 0xF0 ? 3 : 4
      value.bytesize - index < expected ? index : value.bytesize
    end

    def file_stamp(stat)
      [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime]
    end

    def ensure_unchanged!
      raise IOError, "closed file" if closed?
      unchanged = file_stamp(@file.stat) == @stamp && file_stamp(File.stat(@path)) == @path_stamp
      raise Error, "file changed on disk; reopen it" unless unchanged
    rescue Errno::ENOENT
      raise Error, "file changed on disk; reopen it"
    end
  end
end
