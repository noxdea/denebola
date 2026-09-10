# Denebola

Persistent summary B+ trees and Unicode text ropes, in pure Ruby. Ruby 3.1 or later; no runtime dependencies.

Nodes, text chunks, and summaries are frozen. An edit shares untouched subtrees with the previous value. Keeping a snapshot is an ordinary assignment, so readers can keep analyzing old text while an editor creates a new version.

This source is version 0.1.0, not yet published. Build it with `gem build denebola.gemspec`, or use `gem "denebola", path: "/path/to/denebola"` in a Gemfile.

## Text editing

```ruby
require "denebola"

rope = Denebola::Rope.new("hello\nworld")
snapshot = rope
rope = rope.insert(5, ", there")
rope.line(0)                # => "hello, there"
snapshot.to_s               # => "hello\nworld"
rope.bytesize               # => 18
rope.length                 # => 18 Unicode codepoints
rope.line_count             # => 2
rope.byteslice(0, 5).to_s    # => "hello"
rope = rope.delete(0...5)
rope = rope.replace(0...7, "goodbye")
rope.each_chunk { |text| puts text }  # Frozen strings, without flattening
```

All `replace`, `apply_edits`, and `byteslice` ranges address **bytes in UTF-8**, and are checked for bounds and codepoint boundaries. Inclusive and exclusive Ruby ranges work; beginless/endless ranges are accepted. Invalid encodings, split codepoints, and overlapping batch edits raise exceptions. Input strings are copied or shared safely with Ruby's copy-on-write strings; later mutation of the source cannot alter a rope.

`apply_edits([[range, text], ...])` applies nonoverlapping edits against one original snapshot, sorting them into source order. Adjacent ranges are allowed. Chunks preserve extended grapheme clusters when building or joining text; a single unusually long grapheme may exceed the configured chunk size. Explicit byte slices and edits may operate between codepoints inside a grapheme.

```ruby
rope = Denebola::Rope.new("hello\nworld")
rope.apply_edits([[0...5, "Hi"], [6...11, "Ruby"]]).to_s # => "Hi\nRuby"
```

## Lines and positions

LF, CRLF, CR, U+2028, and U+2029 are line breaks. `line(row)` omits its terminator. Rows are zero based; empty text and a final empty row after a terminator each count as a line.

```ruby
rope = Denebola::Rope.new("😀\n日本")
rope.point_at(8)                              # => Point(row: 1, column: 1)
rope.offset_at(Denebola::Point.new(1, 1))     # => 8
rope.line_start(1)                            # => 5
rope.utf16_offset_at(8)                       # => 4
rope.offset_at_utf16(4)                       # => 8
rope.utf16_point_at(4)                        # => Point(row: 0, column: 2)
rope.offset_at_utf16_point(Denebola::Point.new(0, 2)) # => 4
```

`Point` accepts positional or keyword `row` and `column`. Unqualified offsets are UTF-8 byte offsets. Normal columns count Unicode codepoints, not screen cells or graphemes. The UTF-16 methods count code units and reject offsets inside a surrogate pair. `offset_at` and `offset_at_utf16_point` require a column within the line's content. A byte position between CR and LF normalizes to the following row, column zero; converting that point back returns the position after LF.

`rope.summary` exposes `bytesize`, `length`, `utf16_length`, `break_count`, `longest_row` (earliest row with maximum width), `longest_row_length`, `first_line_length`, and `last_line_length`. `TextSummary.zero` is the identity and `summary + other_summary` combines concatenated text, including CRLF across a boundary.

## Anchors

Anchors transform explicitly using the same finite byte ranges as an edit, without retaining the entire edit history:

```ruby
rope = Denebola::Rope.new("hello")
anchor = rope.anchor(2, bias: :right)
edits = [[2...2, "XYZ"]]
anchor = anchor.transform(edits)
rope = rope.apply_edits(edits)
anchor.offset # => 5
```

`:left` keeps an anchor before text inserted at its position; `:right` keeps it after. Anchors covered by a replacement collapse to the corresponding side of the replacement. Offsets after an edit move by its byte-length delta. Anchor transformation returns a new anchor; it does not mutate the original or automatically observe a rope.

## Generic summary tree

Items expose `summary`. The summary class supplies `.zero` and `#+`, with an associative addition and identity. Items and their summaries must be immutable. A dimension is a summary attribute name, a callable, or an object with `from_summary(summary)`; its projection must be monotone along the sequence.

```ruby
Weight = Struct.new(:weight) do
  def self.zero = new(0).freeze
  def +(other) = self.class.new(weight + other.weight).freeze
  def summary = self
end

tree = Denebola::Tree.new([Weight.new(2).freeze, Weight.new(3).freeze], summary: Weight)
tree = tree.push(Weight.new(5).freeze)
cursor = tree.cursor(:weight).seek(2)
cursor.item.weight          # => 3
cursor.summary.weight       # => 2: summary before the current item
cursor.next.weight          # => 5
cursor.prev.weight          # => 3
cursor.seek(2, bias: :left).item.weight # => 2
```

`Tree.from(items, summary: ...)` and `Tree.new(items, summary: ...)` bulk-build an already ordered sequence. `append` joins another compatible tree or enumerable. `tree[index]`, `slice(index, count)`, and `split_at(index)` use item indexes; `replace_at(index, items)` replaces one item, or appends when `index == size`. Every update returns a new tree.

`cursor.seek(value)` chooses the item whose ending dimension exceeds the target; `bias: :left` also includes equality. At the end, `item` is `nil`, `index == tree.size`, and `summary` is the whole summary. `cursor.read_until(value)` returns complete items up to the target boundary and advances the cursor; it does not split an item. `next` and `prev` return the newly selected item or `nil`.

Text dimensions are also available as `Denebola::Dimensions::BYTES`, `CHARACTERS`, `UTF16`, and `LINE_BREAKS`. B+ nodes hold cumulative summaries and item counts; navigation uses binary search. Editing copies touched chunks and ancestor paths, and splitting/joining preserves occupancy and equal leaf depth. Returning a string or a long line necessarily costs at least its output size. `check_invariants!` checks occupancy, frozen nodes, depth, prefix counts, and summaries and is intended for tests.

## Benchmarks and validation

Run `bundle install`, then `bundle exec rake test`. The default suite includes 100,000 deterministic random Unicode edits compared with Ruby `String`, 5,000 summary monoid cases, immutable snapshots, split/join occupancy checks, all supported newline types, surrogate boundaries, and retained node counts after 10,000 edits. `bundle exec rake test:oracle` runs the property tests alone. `ruby tools/check_isolation.rb` checks runtime independence; `sig/denebola.rbs` describes the public API.

`bundle exec rake bench` compares fanouts 8/16/32/64 and chunk sizes 256/512/1024/2048 before exercising a 1,000,000-line ASCII document (11,000,000 bytes). Timings are five-batch medians after warmup. Defaults are fanout **16**, chunk size **1024 bytes**: smaller chunks improve some edits but allocate more nodes; these defaults meet the edit and retained-memory budgets together. Override them with `Rope.new(text, branching: 8, chunk_size: 512)`.

Measured 2026-09-09 on arm64 macOS, Ruby 4.0.2 with YJIT:

| Operation | Measured | Design budget |
|---|---:|---:|
| Build 11 MB | 39.5 ms | 800 ms for 10 MB |
| Insert one ASCII character | 12.3 µs | 50 µs |
| Read a line | 1.38 µs | 5 µs |
| Byte offset → Point | 1.92 µs | 10 µs |
| Point → byte offset | 1.17 µs | 10 µs |
| Slice 1 KB | 6.79 µs | 20 µs |
| Retained Ruby object memory | 33.84 MiB | 40 MiB |

Performance depends on document content, Ruby version, and hardware. Memory is measured with `ObjectSpace` after releasing the input and collecting garbage; it is not process RSS. `rake bench:assert` uses explicitly wider timing ceilings for shared CI hardware, while retaining the 40 MiB memory ceiling. CI tests Ruby 3.1, 3.2, 3.3, 3.4, and 4.0 on Linux, macOS, and Windows.

## License

[MIT](LICENSE.txt).
