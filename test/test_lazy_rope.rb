# frozen_string_literal: true

require_relative "test_helper"
require "objspace"
require "tempfile"

class LazyRopeTest < Minitest::Test
  def with_file(text)
    Tempfile.create("denebola-lazy") do |file|
      file.binmode
      file.write(text)
      file.flush
      rope = Denebola::LazyRope.open(file.path, chunk_size: 4, cache_chunks: 2)
      yield file, rope
    ensure
      rope&.close
    end
  end

  def test_reads_pages_lazily_with_a_bounded_lru
    with_file("abcdefghijklmnop") do |_file, rope|
      assert rope.lazy?
      assert_equal 16, rope.bytesize
      assert_equal "abcd", rope.byteslice(0, 4).to_s
      assert_equal "ijkl", rope.byteslice(8, 4).to_s
      assert_operator rope.cached_bytes, :<=, 8
      assert_equal ["abcd", "efgh", "ijkl", "mnop"], rope.each_chunk.to_a
      assert_operator rope.cached_bytes, :<=, 8
    end
  end

  def test_skips_a_utf8_bom
    with_file("\xEF\xBB\xBFhello".b) do |_file, rope|
      assert_equal 5, rope.bytesize
      assert_equal "hello", rope.to_s
    end
  end

  def test_indexes_all_supported_line_endings_across_chunks
    source = "a\r\nb\rc\nd\u2028e\u2029"
    with_file(source) do |_file, rope|
      assert_operator rope.line_count, :>=, 2
      assert_equal 6, rope.line_count(exact: true)
      assert_equal ["a", "b", "c", "d", "e", ""], (0...6).map { |row| rope.line(row) }
      assert_equal [0, 3, 5, 7, 11, 15], (0...6).map { |row| rope.line_start(row) }
      assert_raises(RangeError) { rope.line(6) }
    end
  end

  def test_line_ends_and_bounded_utf8_windows
    source = "\u03B1\u03B2\u03B3\u{1F600}delta\r\nx\u2028last"
    with_file(source) do |_file, rope|
      first_end = source.b.index("\r\n")
      assert_equal first_end, rope.line_end(0)
      assert_equal source.b.index("\u2028".b), rope.line_end(1)
      assert_equal source.bytesize, rope.line_end(2)

      value, offset = rope.line_window(0, from: 3, max_bytes: 5)
      assert_equal ["\u03B2\u03B3", 2], [value, offset]
      assert value.valid_encoding?
      assert_operator value.bytesize, :<=, 5
      assert_equal ["", first_end], rope.line_window(0, from: 1_000, max_bytes: 8)
      assert_equal ["", 0], rope.line_window(0, max_bytes: 0)
      assert_raises(TypeError) { rope.line_window(0, from: 1.5) }
      assert_raises(ArgumentError) { rope.line_window(0, max_bytes: -1) }
    end
  end

  def test_estimated_line_count_includes_a_cr_at_the_index_boundary
    with_file("abc\rdefgh") do |_file, rope|
      assert_operator rope.line_count, :>=, 2
      assert_equal 2, rope.line_count(exact: true)
    end
  end

  def test_byte_character_and_utf16_positions_match_rope
    source = "a😀\r\n日本\nend"
    eager = Denebola::Rope.new(source, chunk_size: 4)
    boundaries = [0]
    source.each_char { |character| boundaries << boundaries.last + character.bytesize }

    with_file(source) do |_file, lazy|
      boundaries.each do |offset|
        assert_equal eager.point_at(offset), lazy.point_at(offset), "point at byte #{offset}"
        assert_equal eager.utf16_offset_at(offset), lazy.utf16_offset_at(offset), "UTF-16 at byte #{offset}"
        assert_equal eager.utf16_point_at(offset), lazy.utf16_point_at(offset), "UTF-16 point at byte #{offset}"
      end
      (0..eager.utf16_length).each do |units|
        expected = begin
          eager.offset_at_utf16(units)
        rescue RangeError
          :invalid
        end
        if expected == :invalid
          assert_raises(RangeError) { lazy.offset_at_utf16(units) }
        else
          assert_equal expected, lazy.offset_at_utf16(units)
        end
      end
      (0...eager.line_count).each do |row|
        eager_line = eager.line(row)
        (0..eager_line.length).each do |column|
          point = Denebola::Point.new(row, column)
          assert_equal eager.offset_at(point), lazy.offset_at(point)
        end
        utf16_width = eager_line.encode(Encoding::UTF_16LE).bytesize / 2
        (0..utf16_width).each do |column|
          point = Denebola::Point.new(row, column)
          expected = begin
            eager.offset_at_utf16_point(point)
          rescue RangeError
            :invalid
          end
          if expected == :invalid
            assert_raises(RangeError) { lazy.offset_at_utf16_point(point) }
          else
            assert_equal expected, lazy.offset_at_utf16_point(point)
          end
        end
      end
    end
  end

  def test_edits_only_materialize_replaced_ranges_and_reindex_the_suffix
    source = "zero\none😀\ntwo\nthree"
    with_file(source) do |_file, rope|
      assert_equal 4, rope.line_count(exact: true)
      indexed_before = rope.instance_variable_get(:@indexed_offset)

      start = source.index("one")
      finish = start + "one😀".bytesize
      assert_same rope, rope.edit(start...finish, "ONE\nextra")
      expected = "zero\nONE\nextra\ntwo\nthree"
      assert_equal expected, rope.to_s
      assert_equal 5, rope.line_count(exact: true)
      assert_equal (0...5).map { |row| Denebola::Rope.new(expected).line(row) }, (0...5).map { |row| rope.line(row) }
      assert_operator indexed_before, :>, 0
      assert rope.check_invariants!
    end
  end

  def test_random_edits_keep_all_indexes_consistent
    random = Random.new(12_345)
    expected = "alpha\r\n😀 beta\n日本語\u2028omega"
    replacements = ["", "x", "😀", "A\nB", "\r\n", "界"]

    with_file(expected) do |_file, rope|
      100.times do
        boundaries = [0]
        expected.each_char { |character| boundaries << boundaries.last + character.bytesize }
        left_index = random.rand(boundaries.length)
        right_index = random.rand(left_index...boundaries.length)
        start = boundaries[left_index]
        finish = boundaries[right_index]
        replacement = replacements.sample(random: random)
        rope.edit(start...finish, replacement)
        expected = expected.byteslice(0, start) + replacement + expected.byteslice(finish, expected.bytesize - finish)
        eager = Denebola::Rope.new(expected, chunk_size: 4)

        assert_equal expected, rope.to_s
        assert_equal eager.bytesize, rope.bytesize
        assert_equal eager.length, rope.length
        assert_equal eager.utf16_length, rope.utf16_length
        assert_equal eager.line_count, rope.line_count(exact: true)
        expected_boundaries = [0]
        expected.each_char { |character| expected_boundaries << expected_boundaries.last + character.bytesize }
        expected_boundaries.sample([expected_boundaries.length, 4].min, random: random).each do |offset|
          assert_equal eager.point_at(offset), rope.point_at(offset)
          assert_equal eager.utf16_offset_at(offset), rope.utf16_offset_at(offset)
        end
        assert rope.check_invariants!
      end
    end
  end

  def test_insert_delete_and_materialize
    with_file("hello\nworld") do |_file, rope|
      rope.insert(5, ", Ruby").delete(0...1).replace(0...1, "H")
      assert_equal "Hllo, Ruby\nworld", rope.materialize.to_s
      assert_equal "Ruby", rope.materialize(6...10).to_s
      assert_equal 2, rope.line_count(exact: true)
    end
  end

  def test_batched_edits_return_independent_snapshots
    source = "a\u{1F600}\r\nbeta\nomega"
    with_file(source) do |_file, rope|
      changed = rope.apply_edits([
        [1...5, "\u754C"],
        [7...11, "B"],
        [12...12, "!"],
        [12...12, "?"]
      ])

      assert_equal source, rope.to_s
      assert_equal "a\u754C\r\nB\n!?omega", changed.to_s
      refute_same rope, changed

      changed.edit(0...1, "A")
      rope.edit(0...1, "z")
      assert_equal "A\u754C\r\nB\n!?omega", changed.to_s
      assert_equal "z\u{1F600}\r\nbeta\nomega", rope.to_s
      assert_raises(ArgumentError) { rope.apply_edits([[7...11, "x"], [8...8, "y"]]) }
      assert_raises(RangeError) { rope.apply_edits([[2...2, "x"]]) }
    ensure
      changed&.close
    end
  end

  def test_closing_source_or_derived_closes_the_snapshot_family
    with_file("hello") do |_file, rope|
      changed = rope.apply_edits([[0...1, "H"]])
      handle = rope.instance_variable_get(:@file)
      changed.close
      assert changed.closed?
      assert rope.closed?
      assert handle.closed?
      assert_raises(IOError) { changed.to_s }
      assert_raises(IOError) { rope.to_s }
    end

    with_file("hello") do |_file, rope|
      changed = rope.apply_edits([[0...1, "H"]])
      handle = rope.instance_variable_get(:@file)
      rope.close
      assert rope.closed?
      assert changed.closed?
      assert handle.closed?
      assert_raises(IOError) { changed.to_s }
    end
  end

  def test_repeated_snapshots_share_one_file_descriptor
    with_file("hello") do |_file, rope|
      snapshots = [rope]
      50.times { snapshots << snapshots.last.apply_edits([[0...0, "x"]]) }
      handles = snapshots.map { |snapshot| snapshot.instance_variable_get(:@file) }
      assert_equal 1, handles.map(&:object_id).uniq.length
      assert_equal "x" * 50 + "hello", snapshots.last.to_s

      snapshots.last.close
      assert handles.first.closed?
      assert snapshots.all?(&:closed?)
    ensure
      snapshots&.each(&:close)
    end
  end

  def test_retained_history_is_readable_until_the_current_snapshot_closes
    with_file("hello") do |_file, rope|
      history = [rope]
      3.times { |index| history << history.last.apply_edits([[index...index, index.to_s]]) }
      assert_equal ["hello", "0hello", "01hello", "012hello"], history.map(&:to_s)

      history.last.close
      assert history.all?(&:closed?)
      assert history.first.instance_variable_get(:@file).closed?
      history.each { |snapshot| assert_raises(IOError) { snapshot.to_s } }
    ensure
      history&.each(&:close)
    end
  end

  def test_concurrent_family_close_is_idempotent
    with_file("hello") do |_file, rope|
      history = [rope]
      9.times { history << history.last.apply_edits([[0...0, "x"]]) }
      errors = []
      lock = Mutex.new
      threads = 20.times.map do |index|
        Thread.new do
          100.times { history[index % history.length].close }
        rescue StandardError => error
          lock.synchronize { errors << error }
        end
      end
      threads.each(&:join)

      assert_empty errors
      assert history.all?(&:closed?)
      assert history.first.instance_variable_get(:@file).closed?
    ensure
      history&.each(&:close)
    end
  end

  def test_snapshot_construction_failure_leaves_the_owner_open
    with_file("hello") do |_file, rope|
      handle = rope.instance_variable_get(:@file)
      rope.define_singleton_method(:dup) { raise "copy failed" }
      begin
        assert_raises(RuntimeError) { rope.apply_edits([[0...1, "H"]]) }
      ensure
        rope.singleton_class.remove_method(:dup)
      end
      refute rope.closed?
      refute handle.closed?
      assert_equal "hello", rope.to_s
      rope.close
      assert handle.closed?
    end
  end

  def test_shared_file_allows_rename_while_snapshots_are_open
    Dir.mktmpdir("denebola-rename") do |directory|
      path = File.join(directory, "source.txt")
      moved = File.join(directory, "moved.txt")
      File.binwrite(path, "hello")
      rope = Denebola::LazyRope.open(path)
      changed = rope.apply_edits([[0...1, "H"]])

      File.rename(path, moved)
      File.rename(moved, path)
      refute rope.closed?
      refute changed.closed?
    ensure
      changed&.close
      rope&.close
    end
  end

  def test_batched_edits_keep_a_500_mib_sparse_file_lazy
    size = 500 << 20
    Tempfile.create("denebola-large-batch") do |file|
      file.binmode
      file.truncate(size)
      file.seek(size - 5)
      file.write("tail\n")
      file.flush
      rope = Denebola::LazyRope.open(file.path, chunk_size: 65_536, cache_chunks: 2)
      changed = rope.apply_edits([[0...1, "HEAD"], [(size - 5)...size, "tail\u{1F600}\n"]])

      assert_equal size, rope.bytesize
      assert_equal size + 7, changed.bytesize
      assert_equal "\0", rope.byteslice(0, 1).to_s
      assert_equal "tail\n", rope.byteslice(size - 5, 5).to_s
      assert_equal "HEAD", changed.byteslice(0, 4).to_s
      assert_equal "tail\u{1F600}\n", changed.byteslice(changed.bytesize - 9, 9).to_s
      assert_operator rope.cached_bytes, :<=, 131_072
      assert_operator changed.cached_bytes, :<=, 131_072
    ensure
      changed&.close
      rope&.close
    end
  end

  def test_small_changes_do_not_materialize_a_large_text_overlay
    with_file("") do |_file, rope|
      rope.edit(0...0, "x" * (4 * 1024 * 1024))
      GC.start
      GC.disable
      allocated_before = ObjectSpace.memsize_of_all(String)
      rope.insert(rope.bytesize, "y")
      assert_equal "x", rope.byteslice(0, 1).to_s
      allocated = ObjectSpace.memsize_of_all(String) - allocated_before
      assert_operator allocated, :<, 1024 * 1024
    ensure
      GC.enable
    end
  end

  def test_detects_external_changes_even_when_a_page_is_cached
    with_file("unchanged") do |file, rope|
      assert_equal "unch", rope.byteslice(0, 4).to_s
      file.rewind
      file.write("changed!!")
      file.flush
      future = Time.now + 2
      File.utime(future, future, file.path)
      error = assert_raises(Denebola::Error) { rope.byteslice(0, 4) }
      assert_match(/changed on disk/, error.message)
    end
  end

  def test_opening_a_sparse_gibibyte_keeps_a_constant_page_cache
    Tempfile.create("denebola-gib") do |file|
      file.binmode
      file.truncate(1 << 30)
      file.flush
      rope = Denebola::LazyRope.open(file.path, chunk_size: 65_536, cache_chunks: 2)
      assert_equal 1 << 30, rope.bytesize
      assert_equal "\0" * 8, rope.byteslice((1 << 30) - 8, 8).to_s
      assert_operator rope.cached_bytes, :<=, 131_072
    ensure
      rope&.close
    end
  end

  def test_close_is_idempotent
    with_file("text") do |_file, rope|
      assert_nil rope.close
      assert_nil rope.close
      assert rope.closed?
      assert_raises(IOError) { rope.bytesize }
    end
  end
end
