# frozen_string_literal: true

module Denebola
  # An immutable, ordered B+ tree. Items expose #summary; summaries expose .zero and #+.
  class Tree
    include Enumerable
    DEFAULT_BRANCHING = 16

    class Node
      attr_reader :entries, :summary, :prefixes, :counts, :height, :count

      def initialize(entries, height, zero)
        @entries = entries.freeze
        @height = height
        total = zero
        count = 0
        @prefixes = entries.map { |entry| total += entry.summary }.freeze
        @counts = entries.map { |entry| count += height.zero? ? 1 : entry.count }.freeze
        @summary = total
        @count = count
        freeze
      end

      def each(&block)
        if height.zero?
          entries.each(&block)
        else
          entries.each { |child| child.each(&block) }
        end
      end
    end

    attr_reader :root, :summary_class, :branching
    protected :root, :summary_class

    def initialize(items = [], summary:, branching: DEFAULT_BRANCHING, root: nil)
      raise ArgumentError, "branching must be an even integer >= 4" unless branching.is_a?(Integer) && branching >= 4 && branching.even?
      @summary_class = summary
      @branching = branching
      @zero = summary.zero
      @root = root || build(items.to_a)
      freeze
    end

    def self.from(items, **options) = new(items, **options)
    def summary = root ? root.summary : @zero
    def size = root ? root.count : 0
    alias length size
    def empty? = root.nil?

    def each(&block)
      return enum_for(__method__) unless block
      root&.each(&block)
      self
    end

    def [](index)
      return nil unless index.is_a?(Integer) && index >= 0 && index < size
      node = root
      until node.height.zero?
        child = node.counts.bsearch_index { |count| count > index }
        index -= child.zero? ? 0 : node.counts[child - 1]
        node = node.entries[child]
      end
      node.entries[index]
    end

    def push(item) = replace_at(size, [item])

    def append(other)
      other = self.class.new(other, summary: summary_class, branching: branching) unless other.is_a?(Tree)
      raise ArgumentError, "incompatible trees" unless summary_class == other.summary_class && branching == other.branching
      with_root(join_roots(root, other.root))
    end

    # Replace a single item, or insert at the end, copying only its ancestor path.
    def replace_at(index, items)
      raise RangeError, "item index out of bounds" unless index.is_a?(Integer) && index.between?(0, size)
      values = items.to_a
      return slice(0, index).append(values).append(slice(index + 1, size - index - 1)) if values.empty? && index < size
      return self if values.empty?
      if values.length > branching
        finish = [index + 1, size].min
        return slice(0, index).append(values).append(slice(finish, size - finish))
      end
      nodes = replace_node(root, index, values)
      with_root(nodes.length == 1 ? nodes.first : node(nodes, nodes.first.height + 1))
    end

    def split_at(index)
      validate_range(index, 0)
      left, right = split_node(root, index)
      [with_root(left), with_root(right)]
    end

    def slice(index, length = size - index)
      validate_range(index, length)
      return self if index.zero? && length == size
      with_root(slice_node(root, index, length))
    end

    def cursor(dimension) = Cursor.new(self, dimension)

    # [item index, item, cumulative summary before the item].
    def locate(value, dimension, bias: :right)
      raise ArgumentError, "bias must be :left or :right" unless %i[left right].include?(bias)
      prefix = @zero
      index = 0
      current = root
      while current
        slot = current.prefixes.bsearch_index do |entry_summary|
          measure = if prefix.respond_to?(:project_combined) && dimension.is_a?(Symbol)
            prefix.project_combined(dimension, entry_summary)
          else
            project(dimension, prefix + entry_summary)
          end
          bias == :left ? measure >= value : measure > value
        end
        return [size, nil, summary] unless slot
        prefix += current.prefixes[slot - 1] if slot.positive?
        index += current.counts[slot - 1] if slot.positive?
        return [index, current.entries[slot], prefix] if current.height.zero?
        current = current.entries[slot]
      end
      [0, nil, @zero]
    end

    def prefix_summary(index)
      validate_range(index, 0)
      return summary if index == size
      prefix = @zero
      current = root
      while current
        slot = current.counts.bsearch_index { |count| count > index }
        if slot.positive?
          prefix += current.prefixes[slot - 1]
          index -= current.counts[slot - 1]
        end
        break if current.height.zero?
        current = current.entries[slot]
      end
      prefix
    end

    # Raises on an invalid occupancy, depth, count, or cached summary.
    def check_invariants!
      check_node(root, true) if root
      true
    end

    private

    def project(dimension, summary)
      return summary.public_send(dimension) if dimension.is_a?(Symbol) || dimension.is_a?(String)
      return dimension.from_summary(summary) if dimension.respond_to?(:from_summary)
      dimension.call(summary)
    end

    def validate_range(index, length)
      raise RangeError, "item range out of bounds" unless index.is_a?(Integer) && length.is_a?(Integer) && index >= 0 && length >= 0 && index + length <= size
    end

    def with_root(root) = self.class.new(summary: summary_class, branching: branching, root: root)
    def node(entries, height) = Node.new(entries, height, @zero)

    def pack(entries, height)
      return [] if entries.empty?
      count = (entries.length + branching - 1) / branching
      width, extra = entries.length.divmod(count)
      offset = 0
      Array.new(count) do |i|
        length = width + (i < extra ? 1 : 0)
        result = node(entries.slice(offset, length), height)
        offset += length
        result
      end
    end

    def build(items)
      level = pack(items, 0)
      height = 1
      while level.length > 1
        level = pack(level, height)
        height += 1
      end
      level.first
    end

    def replace_node(current, index, values)
      return pack(values, 0) unless current
      entries = current.entries.dup
      if current.height.zero?
        entries[index, index == current.count ? 0 : 1] = values
      else
        slot = current.counts.bsearch_index { |count| count > index } || entries.length - 1
        offset = slot.zero? ? 0 : current.counts[slot - 1]
        entries[slot, 1] = replace_node(entries[slot], index - offset, values)
      end
      pack(entries, current.height)
    end

    def join_roots(left, right)
      return right unless left
      return left unless right
      nodes = join_nodes(left, right)
      nodes.length == 1 ? nodes.first : node(nodes, nodes.first.height + 1)
    end

    def join_nodes(left, right)
      if left.height == right.height
        pack(left.entries + right.entries, left.height)
      elsif left.height > right.height
        pack(left.entries[0...-1] + join_nodes(left.entries.last, right), left.height)
      else
        pack(join_nodes(left, right.entries.first) + right.entries.drop(1), right.height)
      end
    end

    def split_node(current, index)
      return [nil, current] if index.zero?
      return [current, nil] if !current || index == current.count
      return [node(current.entries.take(index), 0), node(current.entries.drop(index), 0)] if current.height.zero?
      slot = current.counts.bsearch_index { |count| count >= index }
      offset = slot.zero? ? 0 : current.counts[slot - 1]
      left, right = split_node(current.entries[slot], index - offset)
      before = current.entries.take(slot)
      after = current.entries.drop(slot + 1)
      prefix = before.empty? ? nil : (before.length == 1 ? before.first : node(before, current.height))
      suffix = after.empty? ? nil : (after.length == 1 ? after.first : node(after, current.height))
      [join_roots(prefix, left), join_roots(right, suffix)]
    end

    def slice_node(current, index, length)
      return nil if length.zero?
      return current if index.zero? && length == current.count
      return node(current.entries.slice(index, length), 0) if current.height.zero?
      slot = current.counts.bsearch_index { |count| count > index }
      offset = slot.zero? ? 0 : current.counts[slot - 1]
      result = nil
      while length.positive?
        child = current.entries[slot]
        local = index - offset
        count = [length, child.count - local].min
        result = join_roots(result, slice_node(child, local, count))
        length -= count
        index += count
        offset += child.count
        slot += 1
      end
      result
    end

    def check_node(current, root)
      minimum = root ? (current.height.zero? ? 1 : 2) : branching / 2
      raise "invalid node occupancy" unless current.entries.length.between?(minimum, branching)
      raise "mutable node" unless current.frozen? && current.entries.frozen?
      actual = @zero
      count = 0
      current.entries.each_with_index do |entry, index|
        if current.height.positive?
          raise "unequal leaf depth" unless entry.height == current.height - 1
          check_node(entry, false)
        end
        actual += entry.summary
        count += current.height.zero? ? 1 : entry.count
        raise "invalid prefix" unless actual == current.prefixes[index] && count == current.counts[index]
      end
      raise "invalid summary" unless actual == current.summary && count == current.count
    end
  end
end
