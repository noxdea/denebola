# frozen_string_literal: true

module Denebola
  class Cursor
    attr_reader :tree, :dimension, :index, :item, :summary

    def initialize(tree, dimension)
      @tree, @dimension = tree, dimension
      @index = 0
      @item = tree[0]
      @summary = tree.prefix_summary(0)
    end

    def seek(value, bias: :right)
      @index, @item, @summary = tree.locate(value, dimension, bias: bias)
      self
    end

    def next
      return nil if index >= tree.size
      @summary += @item.summary
      @index += 1
      @item = tree[index]
    end

    def prev
      return nil if index.zero?
      @index -= 1
      @summary = tree.prefix_summary(index)
      @item = tree[index]
    end

    # Returns complete items from the cursor up to the target dimension boundary.
    def read_until(value, bias: :right)
      finish, = tree.locate(value, dimension, bias: bias)
      raise RangeError, "target is before cursor" if finish < index
      result = tree.slice(index, finish - index)
      seek(value, bias: bias)
      result
    end
  end
end
