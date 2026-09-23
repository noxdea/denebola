# ADR 001: Persistent two-dimensional range-summary index

- Status: Partially implemented (M3 query requirement met; M4/M5 auxiliary-index edits remain)
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

The index is auxiliary and is rebuilt from populated cells after structural
row/column insertions or deletions. This preserves the primary trees' sparse
gap representation and correct snapshots, but makes those structural edits
`O(N)` or more in populated cells. It does not yet satisfy the axis-edit
scaling goal; lazy coordinate shifts or a re-keyable range structure remain a
follow-up rather than a reason to weaken the query bound.

## Validation

Tests compare randomized range summaries with enumerated reference values,
reject `Tree#each` during a partial-column query, and cover sparse distant
coordinates, type-changing replacement, deletion of extrema, and old
snapshots.

On arm64 macOS, Ruby 4.0.6 without YJIT, `bench/sheet_range_index.rb` built
2,000 / 10,000 / 40,000 populated cells over 1,000 / 5,000 / 20,000 occupied
rows in 0.283 / 1.762 / 9.162 s. A one-column query averaged 72.69 / 66.33 /
154.42 µs over 500 queries per size. Query time did not scale linearly with
selected rows, while the build/update cost is significant and must be considered
for large imports. Million-cell behavior with this index has not yet been
measured.

## Remaining work

- Avoid rebuilding the auxiliary index after row/column inserts and deletes.
- Measure retained memory, single-point edit cost, and large dense and sparse
  imports at application-relevant sizes before setting production budgets.
- Revisit index representation if those measurements show the current
  `O(log R × log C × log V)` point-edit or memory costs are unacceptable.
