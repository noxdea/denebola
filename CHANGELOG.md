# Changelog

## 0.3.0 — 2026-09-23

- Add persistent sparse two-dimensional sheets with range summaries.
- Add efficient batch writes for importing sparse or dense cell ranges.

## 0.2.2 — 2026-09-18

- Add persistent batched edits and bounded line-window access to `LazyRope`; related snapshots share one backing-file close lifecycle.

## 0.2.1 — 2026-09-16

- Keep same-offset batch edit ordering deterministic across ropes and anchors.
- Transform right-biased anchors after every insertion and replacement at their boundary.

## 0.2.0 — 2026-09-15

- Add `LazyRope` for bounded-memory access to very large UTF-8 files.
- Build line, character, and UTF-16 indexes incrementally.
- Keep edits as in-memory overlays while untouched bytes remain file-backed.
- Detect files changed or replaced after opening.

## 0.1.0 — 2026-09-10

- Initial release.
