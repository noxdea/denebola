# Changelog

## 0.2.0 — 2026-09-15

- Add `LazyRope` for bounded-memory access to very large UTF-8 files.
- Build line, character, and UTF-16 indexes incrementally.
- Keep edits as in-memory overlays while untouched bytes remain file-backed.
- Detect files changed or replaced after opening.

## 0.1.0 — 2026-09-10

- Initial release.
