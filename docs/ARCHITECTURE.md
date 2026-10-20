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

## Contracts (RondoKit) — implemented in phase 2

Sketch; orchestrator may refine, but must update this file when it does.

```swift
public enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, unknown
}

public struct Format: Hashable, Codable, Sendable, Identifiable {
    public let id: String            // canonical: "jpg", "heic", "mp4", "srt", "tar.gz"
    public let displayName: String   // "JPEG"
    public let kind: FileKind
    public let extensions: [String]  // ["jpg", "jpeg"]
    public let utType: String?       // "public.jpeg"
}
public enum FormatCatalog {          // single source of truth for ids/extensions
    public static let all: [Format]
    public static func format(for url: URL) -> Format?
    public static func kind(for url: URL) -> FileKind
}

public struct ToolID: Hashable, Codable, Sendable, RawRepresentable { public let rawValue: String }   // "image.compress", "video.trim"
public enum ActionID: String, Codable, Sendable, CaseIterable { case airdrop, float, copy, move, copyPath, terminal }

public enum OptionValue: Hashable, Codable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String), ranges([ClosedRange<Double>])
}

public enum Operation: Hashable, Codable, Sendable {
    case convert(to: String)         // Format.id
    case tool(ToolID)
}

public enum Destination: Hashable, Codable, Sendable { case besideOriginal, folder(URL) }

public struct JobSpec: Hashable, Codable, Sendable {
    public var inputs: [URL]
    public var operation: Operation
    public var options: [String: OptionValue]
    public var destination: Destination
}

public enum MultiInput: Sendable { case each, combine, single }

public struct ToolDescriptor: Hashable, Sendable {
    public let id: ToolID
    public let title: String
    public let symbol: String        // SF Symbol name
    public let accepts: Set<FileKind>
    public let multiInput: MultiInput
    public let needsUI: Bool         // true → shell opens the matching editor window first
    public let options: [OptionSpec] // for headless defaults + settings UI
}

public struct ConversionDescriptor: Hashable, Sendable { public let from: String; public let to: String }

public struct JobContext: Sendable {
    public let progress: @Sendable (Double) -> Void    // 0...1, monotonic
    public let log: @Sendable (String) -> Void
    public let tools: ToolLocator
    public let namer: OutputNamer
    public let tempDir: URL                             // per-job; engine writes here, namer moves into place
}

public protocol Engine: Sendable {
    var id: String { get }
    func conversions() -> [ConversionDescriptor]        // runtime-gated
    func tools() -> [ToolDescriptor]                    // runtime-gated
    func run(_ job: JobSpec, context: JobContext) async throws -> [URL]   // honors Task cancellation
}

public final class EngineRegistry: Sendable {
    public init(engines: [any Engine])
    public func convertTargets(for inputs: [URL]) -> [Format]     // intersection across inputs
    public func tools(for inputs: [URL]) -> [ToolDescriptor]
    public func engine(for job: JobSpec) -> (any Engine)?
}

public enum WheelKind: String, Codable, Sendable { case convert, tools, actions }
public enum WheelPayload: Hashable, Sendable { case convert(String), tool(ToolID), action(ActionID) }
public struct WheelItem: Identifiable, Hashable, Sendable { public let id: String; public let title: String; public let symbol: String; public let payload: WheelPayload }
public protocol WheelItemProvider: Sendable { func items(for inputs: [URL], wheel: WheelKind) -> [WheelItem] }

public enum JobEvent: Sendable {
    case queued(UUID, JobSpec), progress(UUID, Double), finished(UUID, [URL]), failed(UUID, String), cancelled(UUID)
}
public actor JobQueue {
    public init(registry: EngineRegistry, heavyLimit: Int = 2)
    public func submit(_ spec: JobSpec) -> UUID
    public func cancel(_ id: UUID)
    public nonisolated var events: AsyncStream<JobEvent> { get }
}

public struct OutputNamer: Sendable {
    public func url(for input: URL, ext: String, suffix: String?, destination: Destination) -> URL   // Finder-style " 2"
    public func folder(for input: URL, suffix: String, destination: Destination) -> URL
    public func commit(_ temp: URL, to final: URL) throws -> URL     // atomic move, re-resolves collisions
}

public struct ToolLocator: Sendable {
    // order: bundle Contents/Resources/bin → Settings override → /usr/local/bin → /opt/homebrew/bin → $PATH
    public func url(for tool: String) -> URL?
}

public enum ProcessRunner {
    public static func run(_ exe: URL, _ args: [String],
                           stdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult
    // terminates child on Task cancellation; captures stderr tail for errors
}
```

## App composition (phase 4)

```
AppDelegate
 ├─ Settings (UserDefaults-backed)
 ├─ EngineRegistry([ImageEngine, PDFEngine, MediaEngine, DocEngine])
 ├─ JobQueue(registry)                 → events → ProgressHUD
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
