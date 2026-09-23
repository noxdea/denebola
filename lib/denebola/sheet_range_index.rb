# frozen_string_literal: true

module Denebola
  class Sheet
    # A persistent row segment tree whose nodes cache a persistent column segment
    # tree. Point edits touch log(row extent) * log(column extent) index nodes.
    class RangeIndex
      class ValueNode
        attr_reader :key, :count, :left, :right, :height, :minimum, :maximum

        def initialize(key, count, left, right)
          @key, @count, @left, @right = key, count, left, right
          @height = 1 + [left&.height || 0, right&.height || 0].max
          @minimum = left ? left.minimum : key
          @maximum = right ? right.maximum : key
          freeze
        end
      end

      module ValueTree
        module_function

        def update(root, key, delta)
          if root.nil?
            raise "missing value in range index" unless delta.positive?
            return ValueNode.new(key, delta, nil, nil)
          end

          comparison = key <=> root.key
          raise ArgumentError, "numeric cell values are not mutually comparable" unless comparison

          if comparison.zero?
            count = root.count + delta
            return remove_root(root) if count.zero?
            raise "negative value count in range index" if count.negative?
            return ValueNode.new(root.key, count, root.left, root.right)
          end

          if comparison.negative?
            balance(ValueNode.new(root.key, root.count, update(root.left, key, delta), root.right))
          else
            balance(ValueNode.new(root.key, root.count, root.left, update(root.right, key, delta)))
          end
        end

        def remove_root(root)
          return root.right unless root.left
          return root.left unless root.right

          successor = root.right
          successor = successor.left while successor.left
          right = update(root.right, successor.key, -successor.count)
          balance(ValueNode.new(successor.key, successor.count, root.left, right))
        end

        def balance(root)
          factor = height(root.left) - height(root.right)
          if factor > 1
            left = root.left
            left = rotate_left(left) if height(left.left) < height(left.right)
            return rotate_right(ValueNode.new(root.key, root.count, left, root.right))
          elsif factor < -1
            right = root.right
            right = rotate_right(right) if height(right.right) < height(right.left)
            return rotate_left(ValueNode.new(root.key, root.count, root.left, right))
          end
          root
        end

        def rotate_left(root)
          pivot = root.right
          left = ValueNode.new(root.key, root.count, root.left, pivot.left)
          ValueNode.new(pivot.key, pivot.count, left, pivot.right)
        end

        def rotate_right(root)
          pivot = root.left
          right = ValueNode.new(root.key, root.count, pivot.right, root.right)
          ValueNode.new(pivot.key, pivot.count, pivot.left, right)
        end

        def height(node) = node&.height || 0
      end

      class ValueBag
        attr_reader :summary, :count

        def initialize(count: 0, sum: 0, types: {}, numbers: nil)
          @count, @sum, @types, @numbers = count, sum, types.freeze, numbers
          @summary = Sheet::Summary.new(count: count, sum: sum,
            min: numbers&.minimum, max: numbers&.maximum, types: @types)
          freeze
        end

        ZERO = new

        def self.zero = ZERO

        def replace(old_value, new_value)
          bag = old_value.nil? ? self : update(old_value, -1)
          new_value.nil? ? bag : bag.update(new_value, 1)
        end

        def update(value, delta)
          return self if delta.zero?

          types = @types.dup
          type_count = types.fetch(value.class, 0) + delta
          raise "negative type count in range index" if type_count.negative?
          type_count.zero? ? types.delete(value.class) : types[value.class] = type_count
          sum = @sum + (value.is_a?(Numeric) ? value * delta : 0)
          numbers = if comparable_number?(value)
            ValueTree.update(@numbers, value, delta)
          else
            @numbers
          end
          self.class.new(count: @count + delta, sum: sum, types: types, numbers: numbers)
        end

        def empty? = count.zero?

        private

        def comparable_number?(value)
          value.is_a?(Numeric) && !(value <=> value).nil?
        end
      end

      class ColumnNode
        attr_reader :left, :right, :bag, :summary

        def initialize(left: nil, right: nil, bag: nil)
          @left, @right, @bag = left, right, bag
          @summary = bag ? bag.summary : summary_of(left) + summary_of(right)
          freeze
        end

        private

        def summary_of(node) = node&.summary || Sheet::Summary.zero
      end

      class ColumnIndex
        attr_reader :root, :capacity

        def initialize(root: nil, capacity: 1)
          @root, @capacity = root, capacity
          freeze
        end

        def update(column, old_value, new_value)
          return self if old_value == new_value

          root, capacity = @root, @capacity
          while column >= capacity
            root = ColumnNode.new(left: root, right: nil) if root
            capacity *= 2
          end
          root = update_node(root, 0, capacity, column, old_value, new_value)
          self.class.new(root: root, capacity: capacity)
        end

        def summary(left, right)
          return Sheet::Summary.zero unless @root && left < @capacity

          query(@root, 0, @capacity, left, [right + 1, @capacity].min)
        end

        def empty? = @root.nil?

        def check_invariants!
          check_node(@root, 0, @capacity) if @root
          true
        end

        private

        def update_node(node, first, finish, column, old_value, new_value)
          if finish - first == 1
            bag = (node&.bag || ValueBag.zero).replace(old_value, new_value)
            return nil if bag.empty?

            return ColumnNode.new(bag: bag)
          end

          middle = (first + finish) / 2
          left, right = node&.left, node&.right
          if column < middle
            left = update_node(left, first, middle, column, old_value, new_value)
          else
            right = update_node(right, middle, finish, column, old_value, new_value)
          end
          return nil unless left || right

          ColumnNode.new(left: left, right: right)
        end

        def query(node, first, finish, left, right)
          return Sheet::Summary.zero unless node && left < finish && first < right
          return node.summary if left <= first && finish <= right

          middle = (first + finish) / 2
          query(node.left, first, middle, left, right) + query(node.right, middle, finish, left, right)
        end

        def check_node(node, first, finish)
          if finish - first == 1
            raise "invalid column-index leaf" unless node.bag && !node.left && !node.right && node.summary == node.bag.summary
            return node.summary
          end
          raise "invalid column-index branch" if node.bag
          middle = (first + finish) / 2
          summary = (node.left ? check_node(node.left, first, middle) : Sheet::Summary.zero) +
            (node.right ? check_node(node.right, middle, finish) : Sheet::Summary.zero)
          raise "incorrect column-index summary" unless node.summary == summary
          summary
        end
      end

      class RowNode
        attr_reader :left, :right, :columns

        def initialize(left, right, columns)
          @left, @right, @columns = left, right, columns
          freeze
        end
      end

      attr_reader :root, :capacity

      def initialize(root: nil, capacity: 1)
        @root, @capacity = root, capacity
        freeze
      end

      def update(row, column, old_value, new_value)
        return self if unchanged_value?(old_value, new_value)

        root, capacity = @root, @capacity
        while row >= capacity
          root = RowNode.new(root, nil, root.columns) if root
          capacity *= 2
        end
        root = update_row(root, 0, capacity, row, column, old_value, new_value)
        self.class.new(root: root, capacity: capacity)
      end

      def summary(top, left, bottom, right)
        return Sheet::Summary.zero unless @root && top < @capacity

        query(@root, 0, @capacity, top, [bottom + 1, @capacity].min, left, right)
      end

      def self.from_rows(rows)
        index = new
        row = 0
        rows.each do |item|
          if item.is_a?(Gap)
            row += item.length
            next
          end
          column = 0
          item.columns.each do |cell|
            if cell.is_a?(Gap)
              column += cell.length
            else
              index = index.update(row, column, nil, cell.value)
              column += 1
            end
          end
          row += 1
        end
        index
      end

      def check_invariants!
        check_row(@root, 0, @capacity) if @root
        true
      end

      private

      def unchanged_value?(old_value, new_value)
        old_value.nil? ? new_value.nil? : !new_value.nil? && old_value.class == new_value.class && old_value == new_value
      end

      def update_row(node, first, finish, row, column, old_value, new_value)
        columns = (node&.columns || ColumnIndex.new).update(column, old_value, new_value)
        if finish - first == 1
          return nil if columns.empty?
          return RowNode.new(nil, nil, columns)
        end

        middle = (first + finish) / 2
        left, right = node&.left, node&.right
        if row < middle
          left = update_row(left, first, middle, row, column, old_value, new_value)
        else
          right = update_row(right, middle, finish, row, column, old_value, new_value)
        end
        return nil if columns.empty?

        RowNode.new(left, right, columns)
      end

      def query(node, first, finish, top, bottom, left, right)
        return Sheet::Summary.zero unless node && top < finish && first < bottom
        return node.columns.summary(left, right) if top <= first && finish <= bottom

        middle = (first + finish) / 2
        query(node.left, first, middle, top, bottom, left, right) +
          query(node.right, middle, finish, top, bottom, left, right)
      end

      def check_row(node, first, finish)
        node.columns.check_invariants!
        return if finish - first == 1

        middle = (first + finish) / 2
        check_row(node.left, first, middle) if node.left
        check_row(node.right, middle, finish) if node.right
      end
    end

    private_constant :RangeIndex
  end
end
