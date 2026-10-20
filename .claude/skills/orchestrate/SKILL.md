---
name: orchestrate
description: Drive the phased, multi-agent build of Rondo (clean-room Tangerine-style macOS file converter) in this repo. Resumes from docs/PROGRESS.md. Use when the user runs /orchestrate or asks to continue, resume, or check status of the Rondo build.
argument-hint: "[next | all | status | phase <N> | ws <W#> | verify] [--max-parallel N]"
disable-model-invocation: true
---

# /orchestrate — build Rondo

You are the orchestrator. You own phase gating, `Package.swift`, `RondoKit` contracts, the `Rondo` app target, `rondo-cli`, integration, verification, and `docs/PROGRESS.md`. Subagents each own one workstream with a disjoint set of paths.

Every run, read first: `CLAUDE.md`, `docs/SPEC.md`, `docs/ARCHITECTURE.md`, `docs/PROGRESS.md`. Read `workstreams.md` (this skill's directory) before launching any subagent.

## Arguments (`$ARGUMENTS`)

| Arg | Effect |
|-----|--------|
| *(empty)* / `next` | Run the first unchecked phase in PROGRESS.md, stop at its gate, report. |
| `all` | Run phases in order until done, a gate fails, or a human check is needed. |
| `status` | Print the phase checklist + blockers from PROGRESS.md. Change nothing. |
| `phase <N>` | Run phase N. If an earlier gate is open, ask before proceeding. |
| `ws <W#>` | (Re)run one workstream, e.g. `ws W4`, then re-run its gate. |
| `verify` | Run phase 7 checks only. |
| `--max-parallel N` | Cap concurrent subagents (default 3; max 5). |

## Hard rules

1. **Clean room.** Obey CLAUDE.md clean-room rules. Never fetch, install, or inspect Tangerine's binary/package/bundle, never run REA or a disassembler on it, never copy its name, icon, screenshots, or copy. Reject any subagent output that does.
2. **Contracts first.** Only you edit `Package.swift`, `Sources/RondoKit/**` public API, `Sources/Rondo/**`, `Sources/rondo-cli/**`, `scripts/**`. A subagent needing a contract change reports the request; you decide, apply it, update `docs/ARCHITECTURE.md`, and tell affected agents.
3. **Disjoint ownership.** Each workstream edits only its owned paths (see `workstreams.md`). After each agent finishes, check `git status --porcelain` for edits outside its paths and revert/flag them.
4. **Build per target.** Agents verify with `swift build --target <T>` on the shared `.build` (SwiftPM serializes the lock; waiting is normal). No extra `--scratch-path` dirs — disk is tight.
5. **Evidence gates.** A phase/workstream is done only when you ran its gate commands and they passed. Show failing output verbatim. Never check a box on an agent's say-so.
6. **Approvals.** Ask the user before: deleting files, `brew install`, editing global/shell config, keychain or TCC/System Settings changes. Never push. At each passed gate, make a local checkpoint commit: `git add -A && git commit -m "P<N>: <summary>"`.
7. **Human-only checks** (Finder drag → wheel, permission prompts, editor UX) go in PROGRESS.md "Manual QA". Ask the user to try them; never mark them verified yourself.
8. **Fix loop cap.** Agent gate fails → `SendMessage` the same agent with exact errors, max 2 rounds. Still failing → take it over yourself or record a blocker and stop.

## Subagent launch protocol

- Tool: `Agent`, `subagent_type: "general-purpose"`, `run_in_background: true`.
- Prompt = **Shared preamble** + the workstream section from `workstreams.md`, verbatim, plus any contract notes from earlier phases.
- Launch all independent workstreams of a phase in **one message** (respecting `--max-parallel`; start queued ones as slots free).
- Don't poll. Wait for completion notifications. Meanwhile do orchestrator-owned work that doesn't touch agent paths.
- On each completion: ownership check → run its gate → mark W box → relay ≤2 lines to the user.

## Phases

### P0 — Preflight (you)
1. If not a git repo: `git init`; write `.gitignore` (`.build/`, `build/`, `fixtures/out/`, `.DS_Store`, `*.xcuserstate`, `.swiftpm/`).
2. Record in PROGRESS.md Toolchain table: `swift --version`, `xcode-select -p`, `which ffmpeg ffprobe magick pandoc soffice`, `security find-identity -v -p codesigning` (read-only), `df -h ~`.
3. Test-framework probe **in the session scratchpad, not the repo**: tiny package with one `import Testing` test → `swift test`; then one `import XCTest` test. Record which works.
4. **Gate:** toolchain recorded; ≥5 GB free (else warn and stop). Commit.

### P1 — Scaffold + drag spike (you, sequential)
1. `Package.swift` (tools 6.0, `.macOS(.v13)`) declaring every target in ARCHITECTURE.md §Layout with a placeholder source file each, so `swift build --target X` works from day one. Test targets per the P0 probe.
2. `Resources/Info.plist`: `CFBundleIdentifier com.farazbukhari.rondo`, `CFBundleExecutable Rondo`, `LSUIElement` true, `LSMinimumSystemVersion 13.0`, `NSAppleEventsUsageDescription`, versions.
3. `scripts/bundle.sh [debug|release]`: `swift build -c <conf> --product Rondo` → assemble `build/Rondo.app/Contents/{MacOS,Resources}` → copy plist/icon → `codesign --force -s "${SIGN_ID:--}"`. Use `SIGN_ID` only if that identity exists. `scripts/run.sh`: bundle, quit running instance, `open build/Rondo.app`.
4. Minimal app: status item with Quit; spike `DragMonitor` + `WheelPanel` (4 dummy slices) in `RondoInteraction` per ARCHITECTURE §Global drag detection; dropped URLs logged via `os_log` and shown in a notification/alert.
5. **Gate:** `swift build` ok; `scripts/bundle.sh` produces `build/Rondo.app`; `scripts/run.sh` then `pgrep -x Rondo` finds it. Then ask the user (AskUserQuestion) to drag a file in Finder and tap Shift: did the wheel appear and did the drop register? If no → log in Decisions, plan the fallback entry points from SPEC §1, continue. Commit.

### P2 — Contracts (you)
1. Implement `RondoKit` per ARCHITECTURE §Contracts: model types, `FormatCatalog` (every format in SPEC §3), `Engine`, `EngineRegistry` (intersection logic), `JobQueue` (heavy-job limit, cancellation), `OutputNamer` (Finder-style collisions, atomic commit), `ToolLocator`, `ProcessRunner` (stdout line streaming, kill on cancel, stderr tail), `Settings`, `WheelItemProvider` default impl.
2. Tests: OutputNamer collisions, FormatCatalog lookups by ext/UTType, registry intersection, ProcessRunner cancel kills child, JobQueue event ordering.
3. **Gate:** `swift build --target RondoKit` + RondoKit tests pass. Update ARCHITECTURE.md if any signature changed. Commit.

### P3 — Workstreams W1–W5 (parallel subagents)
1. Launch W1–W5 per protocol above.
2. Per-workstream gate (you run): `swift build --target <each owned target>` + its tests; ownership check; spot-read 1–2 core files for clean-room + contract compliance.
3. **Gate:** all five checked. Apply any accepted contract requests. Commit.

### P4 — Integration (you)
1. `Sources/Rondo`: composition root per ARCHITECTURE §App composition.
2. `Sources/rondo-cli`: `list <file>` (convert targets + tools), `convert <in...> --to <fmt>`, `tool <id> <in...> [--opt k=v]`, `selftest` (runs core checks when `swift test` is unavailable).
3. `scripts/make-fixtures.sh` (generate small fixtures with ffmpeg testsrc/sine, magick, textutil, Swift — nothing downloaded) and `scripts/smoke.sh` (every v1 conversion + headless tool via rondo-cli; verify outputs with `ffprobe`/`sips`/`file`; print pass/fail table).
4. **Gate:** `swift build`; tests (or `selftest`) pass; `smoke.sh` ≥90% of v1 matrix passes — fill PROGRESS.md Smoke matrix, list every failure; app bundles and launches. Ask user to run Manual QA items 1–6. Commit.

### P5 — Tool windows W6–W8 (parallel subagents)
1. Launch W6–W8. Each `needsUI` tool must also have a headless path covered by smoke.
2. You wire editor windows into the app target.
3. **Gate:** targets build; smoke still ≥90%; UI items added to Manual QA. Commit.

### P6 — Polish (you, optionally one subagent for the icon)
- Settings complete per SPEC §5; permission onboarding (Accessibility/Automation status + System Settings deep links — the user grants, you never do); launch at login via `SMAppService`; original app icon generated by a Swift/CoreGraphics script → `iconutil` → `Resources/AppIcon.icns` (no citrus/Tangerine imagery); release build.
- **Gate:** `scripts/bundle.sh release` ok; app launches; settings persist across relaunch (verify via `defaults read com.farazbukhari.rondo`). Commit.

### P7 — Verify
1. Clean release build: `swift build -c release` (don't delete `.build` without asking).
2. Tests / selftest; `scripts/smoke.sh`; `codesign -dv build/Rondo.app`; launch check.
3. Review: spawn `caveman:cavecrew-reviewer` (fallback `general-purpose`) over `Sources/` for correctness — input-file mutation, leaked processes on cancel, partial outputs beside originals, main-thread blocking, force-unwraps on user files.
4. Clean-room audit: `grep -ri tangerine Sources Resources scripts` must be empty; no binary assets not generated by repo scripts.
5. **Gate:** all green; Manual QA list handed to the user with what remains unverified.

## Reporting

End every run in ≤5 lines: phase reached, gate result (pass/fail + key evidence), what needs the user (human QA, approvals), next command. Update PROGRESS.md before reporting.
