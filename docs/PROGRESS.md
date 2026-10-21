# Rondo — Build Progress

Updated by `/orchestrate`. A box is checked only after the orchestrator ran the gate commands itself.

## Phases

- [x] **P0 Preflight** — git init, toolchain + test-framework probe, disk check
- [x] **P1 Scaffold + drag spike** — Package.swift with all targets, bundle/run scripts, menu-bar app launches, Finder drag → Shift → wheel spike
- [x] **P2 Contracts** — RondoKit per ARCHITECTURE.md, unit tests
- [x] **P3 Workstreams** — W1 Interaction · W2 Shell+Actions · W3 Image+PDF · W4 Media · W5 Docs
  - [x] W1  - [x] W2  - [x] W3  - [x] W4  - [x] W5
- [x] **P4 Integration** — registry wiring, app composition, rondo-cli, fixtures, smoke matrix
- [x] **P5 Tool windows** — W6 Image editor · W7 Media editor · W8 PDF organizer
  - [x] W6  - [x] W7  - [x] W8
- [ ] **P6 Polish** — settings complete, original icon, release build, launch at login, permission onboarding
- [ ] **P7 Verify** — clean release build, tests, smoke, review pass, clean-room audit

## Toolchain (P0 fills)

| Item | Value |
|------|-------|
| swift | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), target x86_64-apple-macosx26.0 |
| developer dir | /Library/Developer/CommandLineTools (no Xcode.app) |
| ffmpeg / ffprobe / magick / pandoc / soffice | ffmpeg 8.1.2, ffprobe, ImageMagick 7.1.2-27 at /usr/local/bin · pandoc missing · soffice missing |
| codesign identities | 0 valid → ad-hoc signing (`-`) |
| free disk | 24 GiB (93% used) on 2026-10-21 |
| `swift test` support | **Swift Testing: yes, only with CLT framework flags → use `scripts/test.sh [filter]`** (plain `swift test` fails: no such module 'Testing'). XCTest: no. Linker warns Testing.framework built for macOS 14 — harmless. |

## Smoke matrix (P4/P7 fill)

Full run 2026-10-21 (P4 gate), `scripts/smoke.sh`, 4 engines, 403 conversions + 32 tools on this Mac:

| Kind | Pass | Fail | Notes |
|------|------|------|-------|
| image | 222 | 0 | QR read only on `qr.png` fixture |
| video | 146 | 0 | |
| audio | 128 | 0 | |
| pdf | 24 | 0 | 3 initial fails were correct "No text found" errors on image-only `images.pdf` (→ md/docx/epub); reclassified as expected, PDF slice re-run 24/24 |
| document | 67 | 0 | |
| spreadsheet | 12 | 0 | |
| subtitle | 10 | 0 | |
| archive | 4 | 0 | |
| folder | 3 | 0 | |
| **total** | **616** | **0** |

P5 re-run 2026-10-21 (editors wired): 616/616, expected errors 5/5. Tests 386/386 (73 suites).

