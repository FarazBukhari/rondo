# Rondo — Architecture

SwiftPM-only (no Xcode.app). One package, many small targets so parallel agents can build their module with `swift build --target X` without breaking each other.

## Layout

```
Package.swift
Resources/Info.plist            # copied into the bundle by scripts/bundle.sh
Resources/AppIcon.icns          # original art, generated (phase 6)
Sources/
  RondoKit/                     # contracts + support. Orchestrator-owned.
    Model/      FileKind, Format, FormatCatalog, Operation, JobSpec, OptionValue, ToolDescriptor, Wheel*
    Engine/     Engine protocol, JobContext, EngineRegistry
    Support/    ProcessRunner, ToolLocator, OutputNamer, TempDir, Settings
    Queue/      JobQueue, JobEvent
  ImageEngine/                  # W3
  PDFEngine/                    # W3
  MediaEngine/                  # W4 (video + audio, ffmpeg)
  DocEngine/                    # W5 (documents, subtitles, archives, spreadsheets, slides)
  RondoInteraction/             # W1 (DragMonitor, WheelPanel, WheelView, WheelModel, keyboard)
  RondoShell/                   # W2 (status item, progress HUD, settings, actions, Float shelf, hotkey)
  ImageEditorUI/                # W6
  MediaEditorUI/                # W7
  PDFOrganizerUI/               # W8
  Rondo/                        # app executable: main.swift, AppDelegate, composition root. Orchestrator-owned.
  rondo-cli/                    # headless harness: convert / tool / list / selftest. Orchestrator-owned.
Tests/<Target>Tests/
scripts/  bundle.sh run.sh make-fixtures.sh smoke.sh
fixtures/ (generated, gitignored outputs in fixtures/out/)
```

Dependency rule: every target → `RondoKit`. `*UI` targets → their engine too. `Rondo` and `rondo-cli` → everything they need. Nothing depends on `Rondo`.

## Contracts (RondoKit) — as built in P2

Source of truth is `Sources/RondoKit/**`; this is the map. Change only via the orchestrator.

| File | Public API |
|------|-----------|
| `Model/Format.swift` | `FileKind` (+ `symbol`, `isHeavy`), `Format` (`id`, `displayName`, `kind`, `extensions`, `utType`, `preferredExtension`) |
| `Model/FormatCatalog.swift` | `FormatCatalog.all` (wheel order), `format(id:)`, `format(utType:)`, `format(for: URL)` (compound ext first, plain dirs → `folder`), `kind(for:)`, `rank(_:)` |
| `Model/Job.swift` | `ToolID` (string literal), `ActionID` (+ `title`, `symbol`), `OptionValue` (`bool/int/double/string/ranges/list`), `Operation` (`.convert(to:)`, `.tool`), `Destination`, `JobSpec` (+ typed getters `bool/int/double/string/ranges/list`), `MultiInput` (`.each`, `.combine(minimum:)`, `.single`), `OptionSpec`, `ToolDescriptor` (+ `defaultOptions`), `ConversionDescriptor`, free func `conversions(from:to:)` (cartesian, skips identity) |
| `Model/Wheel.swift` | `WheelKind`, `WheelPayload`, `WheelItem`, `WheelItemProvider`, `RegistryWheelItemProvider(registry:)` |
| `Engine/Engine.swift` | `Engine` protocol (`id`, `conversions()`, `tools()`, `run(_:context:) async throws -> [URL]`), `JobContext` (`progress`, `log`, `tools`, `namer`, `tempDir`, `destination`, `tempFile(named:)`, `outputURL(for:ext:suffix:)`), `EngineError` (`unsupported/missingTool/invalidInput/failed`) |
| `Engine/EngineRegistry.swift` | `EngineRegistry(engines:)`, `allConversions`, `allTools`, `supports(from:to:)`, `convertTargets(for:)`, `tools(for:)`, `tool(_:)`, `engine(for:)`, `refreshed()` |
| `Queue/JobQueue.swift` | `JobEvent` (`queued/started/progress/finished/failed/cancelled`, `jobID`, `isTerminal`), `actor JobQueue(registry:heavyLimit:totalLimit:tools:)`: `subscribe()` (nonisolated, one stream per subscriber), `submit(_:) -> [UUID]`, `cancel(_:)`, `cancelAll()`, `activeCount` |
| `Support/OutputNamer.swift` | `url(for:ext:suffix:destination:)`, `folder(for:suffix:destination:)`, `commit(_:to:)`, `static baseName(of:)`, `static unique(_:)` |
| `Support/ToolLocator.swift` | `ToolLocator(overrides:bundleBin:)`, `fromSettings(_:)`, `url(for:)`, `has(_:)`, `require(_:) throws` |
| `Support/ProcessRunner.swift` | `ProcessRunner.run(_:_:currentDirectory:environment:stdin:stdoutLine:checkExit:) async throws -> ProcessResult`; `ProcessError` (`exitCode`, `stderrTail`) |
| `Support/TempDir.swift` | `TempDir.root`, `make(prefix:)`, `remove(_:)` (refuses paths outside root) |
| `Support/Settings.swift` | `Settings` (lenient Codable, `load(from:)`, `save(to:)`, `wheel(for:)`), `ModifierKey`, `Hotkey` |

Behavior rules engines rely on:

- **Batch splitting:** the queue splits `.convert` and `.each` tools into one job per input and skips inputs already in the target format. `.combine`/`.single` tools get all inputs in one job.
- **Batch targets:** `convertTargets` = formats reachable from every input (an input already in that format counts), excluding targets that no input needs.
- **Outputs:** write into `context.tempFile(named:)`, then `context.namer.commit(temp, to: context.outputURL(for: input, ext:, suffix:))`. Multi-file results: build the folder in temp, commit it to `namer.folder(for:suffix:destination:)`.
- **Progress:** call `context.progress` freely; the queue clamps, keeps it monotonic, rate-limits, and sends the final `1.0` itself.
- **Cancellation:** `ProcessRunner` kills the child and throws `CancellationError`; long Swift loops call `try Task.checkCancellation()`. The queue deletes the job's temp dir.
- **Tool option keys** (shared by engines, CLI `--opt k=v`, editors): `quality` (0…1), `percent` (0…100, size reduction), `targetBytes` (Int), `width`/`height` (px), `rect` (`list` x,y,w,h in source pixels, top-left origin), `ranges` (seconds or 1-based pages), `order` (`list`, 1-based pages), `speed` (Double), `dpi` (Int).

## App composition (phase 4)

```
AppDelegate
 ├─ Settings (UserDefaults-backed)
 ├─ EngineRegistry([ImageEngine, PDFEngine, MediaEngine, DocEngine])
 ├─ JobQueue(registry)                 → subscribe() → ProgressHUD
 ├─ WheelItemProvider(registry, ActionID.allCases)
 ├─ DragMonitor ──(files + modifier tap)──▶ WheelPanel.present(inputs, at: cursor, kind, mode: .drag)
 ├─ StatusItem drop / Hotkey / Float drop ─▶ WheelPanel.present(..., mode: .click)
 └─ WheelPanel selection ─▶ payload
        .convert/.tool(needsUI=false) → JobQueue.submit
        .tool(needsUI=true)           → open ImageEditor / MediaEditor / PDFOrganizer → JobQueue.submit
        .action                       → RondoShell.Actions
```

## Global drag detection (W1) — highest risk

- `NSEvent.addGlobalMonitorForEvents([.leftMouseDragged, .leftMouseUp, .flagsChanged])`.
- Drag in progress with files ⇔ `NSPasteboard(name: .drag).changeCount` changed since mouse-down **and** it yields file URLs (`readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`).
- Modifier "tap" during drag (press, or press+release < 350 ms) → open wheel of mapped kind.
- `WheelPanel`: `NSPanel`, `.nonactivatingPanel`, borderless, clear background, level `.popUpMenu`, centered on cursor and clamped to the screen's visible frame.
- Slices hit-tested by angle/radius inside one AppKit `NSView` registered for `.fileURL` drags; `draggingUpdated` highlights, `performDragOperation` returns `.copy` (so Finder never moves the source) and fires selection.
- Keyboard (arrows / Enter / Esc) during a drag needs a global key monitor → Accessibility permission. Optional; prompt only from Settings.
- ≤8 slices per ring; overflow ring outside. Center hub = file icon + count + cancel.

## Risks

| Risk | Mitigation |
|------|------------|
| Global mouse monitor or drag pasteboard unreliable on macOS 26 | Phase 1 spike gates it. Fallbacks: status-item drop, Float drop, hotkey + Finder selection, Services Quick Action — all reuse `WheelPanel` in click mode. |
| Ad-hoc signing changes cdhash each build → TCC grants (Accessibility, Automation) reset every rebuild | `bundle.sh` uses identity `$SIGN_ID` if present. User may create a self-signed "Rondo Dev" code-signing cert in Keychain Access themselves; otherwise re-grant after rebuilds. |
| `swift test` / XCTest missing with CLT-only | Phase 0 probe; fallback `rondo-cli selftest`. |
| ImageIO can't write WebP/AVIF on this macOS | Gate at runtime via `CGImageDestinationCopyTypeIdentifiers()`; use `magick`. |
| Intel HEVC/HEIC encode | T2 Macs support it; gate on ImageIO/VideoToolbox availability. |
| Disk (~24 GB free) | One shared `.build`; fixtures small; outputs in `fixtures/out/` (gitignored). |
