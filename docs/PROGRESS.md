# Rondo — Build Progress

Updated by `/orchestrate`. A box is checked only after the orchestrator ran the gate commands itself.

## Phases

- [x] **P0 Preflight** — git init, toolchain + test-framework probe, disk check
- [x] **P1 Scaffold + drag spike** — Package.swift with all targets, bundle/run scripts, menu-bar app launches, Finder drag → Shift → wheel spike
- [x] **P2 Contracts** — RondoKit per ARCHITECTURE.md, unit tests
- [x] **P3 Workstreams** — W1 Interaction · W2 Shell+Actions · W3 Image+PDF · W4 Media · W5 Docs
  - [x] W1  - [x] W2  - [x] W3  - [x] W4  - [x] W5
- [x] **P4 Integration** — registry wiring, app composition, rondo-cli, fixtures, smoke matrix
- [ ] **P5 Tool windows** — W6 Image editor · W7 Media editor · W8 PDF organizer
  - [ ] W6  - [ ] W7  - [ ] W8
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
| **total** | **616** | **0** | + 5/5 expected errors correct. Slides untestable here (no Keynote/soffice → not advertised) |

## Manual QA (human only — never auto-checked)

- [x] Finder drag + Shift → Convert wheel at cursor; drop on slice converts — user-confirmed 2026-10-21
- [x] Finder drag + Option → Tools wheel; Control → Actions wheel — user-confirmed 2026-10-21
- [ ] Wheel stays open after key release; Esc / drop-outside cancels
- [ ] Arrow keys + Enter during drag (Accessibility granted)
- [x] Batch drag (5 mixed images) → only shared formats shown; HUD shows 5 jobs; Finder reveals outputs — user-confirmed 2026-10-21
- [x] Status-item drop, hotkey on Finder selection, Float shelf drag-out — user-confirmed 2026-10-21
- [ ] AirDrop / Copy / Move / Copy Path / Terminal actions (Copy Path / Float / Terminal user-confirmed; AirDrop / Copy / Move untested)
- [ ] Editor windows: image crop/annotate/redact, video trim/split, PDF reorder
- [ ] Settings: remap modifiers persists across relaunch; launch at login

## Decisions log

| Date | Decision | Why |
|------|----------|-----|
| 2026-10-20 | Clean-room from public sources; REA not used on Tangerine | No Intel binary obtainable; EULA bars reverse engineering; REA scope = owned/authorized software |
| 2026-10-20 | Default keys Shift/Option/Control | Public sources conflict; all remappable |
| 2026-10-21 | Global drag detection = NSEvent global mouse monitors + drag pasteboard + polled `NSEvent.modifierFlags`; no Accessibility needed | P1 spike: user confirmed wheel + drop in Finder; logs show `drag began` → `modifier tap` → `drop on slice` |
| 2026-10-21 | Tests via `scripts/test.sh` (Swift Testing + CLT framework flags); package uses Swift 5 language mode | No XCTest in CLT; strict-concurrency friction with AppKit monitors |
| 2026-10-21 | W1 default trigger policy `.press` (opens on key-down) | Fastest; risk: ⌥ to force Finder copy opens Tools wheel. Revisit in P6 (`.standardTap` = open on quick release) |
| 2026-10-21 | DocumentEngine also archives PDFs (pdf → zip/tar.gz/gz) | PDF engine never advertises archive targets; otherwise PDFs were the only unarchivable files |
| 2026-10-21 | Archive targets (ZIP/TAR.GZ/GZIP) shown on every file's Convert wheel, sorted last (overflow ring) | Mirrors Finder "Compress"; revisit clutter in P6 |
| 2026-10-21 | `ToolDescriptor.rejectsFormats` + `OptionSpec.Control.rect/list/json` added to contracts | Smoke showed SVG tools advertised but unsupported; editors need typed option specs |

## Blockers

(none)
