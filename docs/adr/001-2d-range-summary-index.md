# ADR 001: Defer a two-dimensional range-summary index

- Status: Deferred
- Date: 2026-09-23

## Context

`Sheet#summary` uses the row B+ tree's cached summaries when the requested range
covers all columns. For a partial-column rectangle it first isolates the row
range, then visits each occupied row and queries that row's column tree. Its
cost is `O(log_B R + k log_B C)`, where `k` is the number of occupied rows in
the range and `R`/`C` are the row/column tree sizes. It does not visit individual
cells, but its cost grows linearly with the number of occupied rows.

On Ruby 4.0.6 arm64, 20 repeated one-column summaries took 4.633 ms per query
for 1,000 occupied rows and 24.630 ms for 5,000 rows (build times 114.3 ms and
701.7 ms). A 100,000-cell benchmark with 100 occupied rows reported 11.192 ms
for a partial-column summary versus 11 µs for a full-row summary. This confirms
the partial-column path is row-count-bound; it does not meet X5 M3's
“without scanning the range” criterion.

## Decision

Do not add a mirrored per-column index as the M3 implementation. It could trade
row visits for column visits, but would still scan one selected dimension. It
would also need synchronized persistent row-order indexes across row inserts
and deletes, and mirrored column-order indexes across column edits. This is a
useful heuristic only when one dimension is known to be narrow; it does not
provide the required range-independent query bound.

Defer M3 until a dedicated persistent two-dimensional range structure can be
designed and measured. The existing generic B+ tree combines child summaries
by replaying `+`; placing a column index in each row summary would therefore
rebuild/merge potentially large indexes on ordinary path copies, making point
updates proportional to subtree width rather than `O(log R log C)`.

## Required follow-up

An implementation should support canonical row and column range decomposition
with `O(log R log C)` query work, `O(log R log C)` copied index nodes per point
update, and structural row/column edits that do not enumerate all stored cells
or empty coordinates. A purpose-built persistent 2D tree (or an equivalent
index with proven bounds) is needed; its retained memory, edit costs, and
snapshot sharing must be benchmarked against the current row/column trees
before replacing them. Until that work is complete, partial-column `summary`
is correct but does not satisfy M3.
