# ADR 001: Persistent two-dimensional range-summary index

- Status: Implemented with a fragmented-axis query trade-off
- Date: 2026-09-23

## Context

`Sheet#summary` must return count, sum, min, max, and type counts for arbitrary
rectangles without walking the selected rows or cells. The row/column B+ trees
already cache whole-axis summaries, but those summaries alone make an
arbitrary partial-column query proportional to the number of occupied rows.

## Decision

Keep the existing sparse B+ trees as the canonical sheet storage and maintain a
separate immutable 2D range index. Its outer sparse binary segment tree indexes
row coordinates; every outer node owns an inner sparse segment tree indexed by
columns. Each inner leaf stores a summary bag for all values in that column
across the outer node's row interval. A rectangle decomposes into canonical
row nodes and column nodes, so a partial summary touches `O(log R × log C)`
coordinate nodes and does not enumerate rows or cells.

Point edits path-copy the outer row path and the inner column path in each row
node, sharing all unaffected nodes with prior snapshots. Count, sum, and type
counts are cached in each summary bag. Comparable numeric values also use a
persistent AVL multiset so deleting a current minimum or maximum restores the
next value. Thus coordinate-path work is `O(log R × log C)`; exact extrema
maintenance adds `O(log V)` value-tree work for each changed inner leaf, where
`V` is the number of distinct comparable numeric values in that row interval.
For a sheet no wider than one column, the 2D index is unnecessary: every valid
column query is a whole-width query already answered by the row B+ tree. Build
the index only when a sheet becomes wider, and discard it when structural
column deletion returns the sheet to one column.

The index is auxiliary. Each sheet snapshot maps its current row and column
coordinates to stable index coordinates using coalesced runs. Structural
insertions add a run and shift only the primary sheet storage; deletions remove
the deleted cells from the index and drop the corresponding runs. Surviving
cells keep their index coordinates, so these edits never rebuild or re-key all
indexed cells. Old snapshots retain their old maps and indexes.

With an unfragmented axis, a partial query still uses one index rectangle.
After structural edits split an axis into `S` runs, a query decomposes into at
most `S_rows × S_columns` rectangles. The run maps are flat immutable arrays,
so an edit costs `O(S)` and query decomposition costs `O(S_rows × S_columns)`;
the subsequent index queries retain their logarithmic coordinate bounds. Row
insertions avoid scanning stored rows. The canonical column tree still visits
stored rows for column insertions/deletions, and deleting populated rows or
columns must visit the cells actually removed. A persistent interval map and
faster primary-tree column edits remain follow-ups if fragmented axes or those
row scans become measured bottlenecks.

## Validation

Tests compare randomized range summaries with enumerated reference values,
reject `Tree#each` during a partial-column query, and cover sparse distant
coordinates, type-changing replacement, deletion of extrema, and old
snapshots.

On arm64 macOS, Ruby 4.0.6 without YJIT, `bench/sheet_range_index.rb` built
2,000 / 10,000 / 40,000 populated cells over 1,000 / 5,000 / 20,000 occupied
rows in 0.283 / 1.762 / 9.162 s. A one-column query averaged 72.69 / 66.33 /
154.42 µs over 500 queries per size. After the stable-axis change, a focused
run with 2,000 / 10,000 cells measured row insert/delete at 0.001 / 0.006 s and
column insert/delete at 0.072 / 0.335 s; the latter still reflects primary
tree row traversal. It measured partial-column queries at 71.85 / 102.00 µs
over 20 queries. These small samples are regression checks, not production
budgets. Build/update cost is significant and must be considered for large
imports; retained memory and million-cell behavior have not been measured.
After avoiding the redundant index on one-column sheets, Rukbat's 100k
formula-chain benchmark completed load/recalculate in 4.965 s and
source-edit/recalculate in 1.870 s (below its 3 s recalculation gate); before
the specialization these were 13.96 s and 16.592 s.

## Remaining work

- Measure retained memory, single-point edit cost, and large dense and sparse
  imports at application-relevant sizes before setting production budgets.
- Replace flat axis runs with a persistent interval map if repeated structural
  edits make coordinate translation or rectangle decomposition a bottleneck.
- Avoid traversing every stored row for primary-tree column edits if benchmarks
  show the measured linear scaling is unacceptable.
- Revisit index representation if those measurements show the current
  `O(log R × log C × log V)` point-edit or memory costs are unacceptable.
