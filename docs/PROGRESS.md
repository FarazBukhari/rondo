# Rondo — Build Progress

Updated by `/orchestrate`. A box is checked only after the orchestrator ran the gate commands itself.

## Phases

- [x] **P0 Preflight** — git init, toolchain + test-framework probe, disk check
- [ ] **P1 Scaffold + drag spike** — Package.swift with all targets, bundle/run scripts, menu-bar app launches, Finder drag → Shift → wheel spike
- [ ] **P2 Contracts** — RondoKit per ARCHITECTURE.md, unit tests
- [ ] **P3 Workstreams** — W1 Interaction · W2 Shell+Actions · W3 Image+PDF · W4 Media · W5 Docs
  - [ ] W1  - [ ] W2  - [ ] W3  - [ ] W4  - [ ] W5
- [ ] **P4 Integration** — registry wiring, app composition, rondo-cli, fixtures, smoke matrix
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

| Kind | Pass | Fail | Notes |
|------|------|------|-------|

## Manual QA (human only — never auto-checked)

- [ ] Finder drag + Shift → Convert wheel at cursor; drop on slice converts
- [ ] Finder drag + Option → Tools wheel; Control → Actions wheel
- [ ] Wheel stays open after key release; Esc / drop-outside cancels
- [ ] Arrow keys + Enter during drag (Accessibility granted)
- [ ] Batch drag (5 mixed images) → only shared formats shown; HUD shows 5 jobs; Finder reveals outputs
- [ ] Status-item drop, hotkey on Finder selection, Float shelf drag-out
- [ ] AirDrop / Copy / Move / Copy Path / Terminal actions
- [ ] Editor windows: image crop/annotate/redact, video trim/split, PDF reorder
- [ ] Settings: remap modifiers persists across relaunch; launch at login

## Decisions log

| Date | Decision | Why |
|------|----------|-----|
| 2026-10-20 | Clean-room from public sources; REA not used on Tangerine | No Intel binary obtainable; EULA bars reverse engineering; REA scope = owned/authorized software |
| 2026-10-20 | Default keys Shift/Option/Control | Public sources conflict; all remappable |

## Blockers

(none)
