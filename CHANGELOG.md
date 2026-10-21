# Changelog

All notable changes to Rondo. Versions follow [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-10-21

First public release.

- Drag-and-tap radial wheel over any file drag: **⇧** Convert, **⌥** Tools, **⌃** Actions (remappable; open on key-down or on a quick tap).
- Also opens from the menu-bar icon, the floating shelf, and **⌃⌥Space** on the Finder selection.
- Conversions across images, video, audio, PDF, documents, spreadsheets, subtitles and archives; batch drags show only formats every file supports.
- Tools: compress (quality, percent or exact size), resize, crop, adjust, annotate, redact, background, QR reader, images → PDF, collage; video trim/crop/speed/split/join/snapshot; audio normalize/trim/bleep/channels; PDF merge/split/reorder/extract text (OCR); metadata view/strip.
- Editors: image editor, video/audio editor with timeline, PDF page organizer.
- Actions: AirDrop, Float shelf, Copy, Move (safe across drives), Copy Path, Terminal.
- Progress panel with per-job cancel; results revealed in Finder; originals never modified.
- Archive extraction refuses path traversal, escaping links and decompression bombs.
- Everything runs locally; no network access.
