# Workstream briefs

Paste **Shared preamble** + one workstream section into each subagent prompt.

---

## Shared preamble

You are building one workstream of **Rondo**, a clean-room macOS menu-bar file converter (Swift 6.3, SwiftPM only, Command Line Tools only — no Xcode.app, no `xcodebuild`). Repo: `/Users/farazbukhari/Code/Personal_Projects/tangerine-clone`.

Read first: `CLAUDE.md`, `docs/ARCHITECTURE.md` (contracts — code against `RondoKit` exactly), and the `docs/SPEC.md` sections named in your brief.

Rules:
- Edit **only** your owned paths. Do not touch `Package.swift`, `Sources/RondoKit/**`, `Sources/Rondo/**`, `Sources/rondo-cli/**`, `scripts/**`, or other workstreams' paths. If you need a contract change, finish what you can against the current API and put the exact request (signature + reason) in your report.
- Clean room: behavior from SPEC only. Never fetch, inspect, or reference Tangerine binaries, assets, or copy. All visuals original.
- Never modify input files. Write outputs to `context.tempDir`, then `context.namer.commit(...)`.
- Shell out only via `ProcessRunner`; find tools only via `context.tools` / `ToolLocator`. Gate capabilities at runtime on tool presence and ImageIO/AVFoundation support.
- Honor `Task` cancellation; report progress 0→1 monotonically.
- Verify: `swift build --target <T>` for each target you own; tests in `Tests/<T>Tests/` (framework per `docs/PROGRESS.md` Toolchain row; if `swift test` unsupported, put checks in a `static func selfTest() throws` on your engine and say so). Shared `.build` lock waits are normal. Small generated fixtures only (ffmpeg testsrc/sine, magick, textutil) — no downloads, written under `fixtures/out/<W#>/`.
- Don't commit, don't `brew install`, don't delete files outside your paths, don't change system settings.
- Report (≤20 lines): files created; capabilities implemented (conversion pairs / tool IDs); stubs or gaps; last lines of build + test output; contract requests; risks.

---

## W1 — Interaction (drag detection + wheel)

Target: `RondoInteraction`. Owns `Sources/RondoInteraction/**`, `Tests/RondoInteractionTests/**`.
SPEC: §1, §2 (wheel display only). ARCHITECTURE: §Global drag detection.

Build on the P1 spike:
- `DragMonitor`: global monitors for `.leftMouseDragged`, `.leftMouseUp`, `.flagsChanged`; file-drag detection via `NSPasteboard(name: .drag)` changeCount + file URLs; modifier tap state machine driven by `Settings` modifier→`WheelKind` map; emits `(urls, kind, cursorPoint)`. Pure state machine split out for tests.
- `WheelPanel`: non-activating borderless clear `NSPanel` at `.popUpMenu` level, centered on cursor, clamped to visible frame, fade/scale-in ≤120 ms. API: `present(inputs:at:kind:mode:)` with `mode: .drag | .click`, `dismiss()`, `onSelect: (WheelItem, [URL]) -> Void`.
- `WheelView` (AppKit `NSView`, layer-backed): radial slices with SF Symbol + label, ≤8 per ring + overflow ring, center hub (file icon, count, cancel). Drag mode: registered for `.fileURL`, highlight on `draggingUpdated`, `performDragOperation` returns `.copy`. Click mode: hover + click. Dark/light aware. Original look.
- `WheelModel` (pure): items from `WheelItemProvider`, slice geometry (angle/radius hit test), keyboard nav (←/→ cycle, ↑/↓ ring, Enter apply, Esc cancel).
- Keyboard during drag: global keyDown monitor active only if `AXIsProcessTrusted()`; never prompt from here (Settings owns prompting).
- Tests: hit-test geometry, ring overflow layout, nav wraparound, modifier-tap state machine with synthetic event sequences (tap, hold, release-before-drag, drag ends without key).

## W2 — Shell + Actions

Target: `RondoShell`. Owns `Sources/RondoShell/**`, `Tests/RondoShellTests/**`.
SPEC: §1.1, §1.10, §1.11, §2, §5.

- `StatusItemController`: menu (Recent outputs ▸ reveal, Show Float shelf, Settings…, Permissions…, Quit); button accepts file drops → callback to open wheel in click mode.
- `ProgressHUD`: floating panel listing active/recent jobs from `JobQueue.events` — name, kind icon, progress bar, cancel, error text; on finish reveal outputs (`NSWorkspace.activateFileViewerSelecting`); auto-hide when idle.
- `SettingsWindow` (SwiftUI in `NSHostingController`): modifier mapping, default qualities, output destination, hotkey recorder, launch at login (`SMAppService.mainApp`), tool paths with detected status, permission status (Accessibility via `AXIsProcessTrusted`, Automation) with buttons that open the right System Settings pane — user grants, code never changes settings.
- `Hotkey`: Carbon `RegisterEventHotKey` (no permission needed) → Finder selection via `NSAppleScript` (`tell application "Finder" to get selection as alias list`) → callback to open wheel in click mode at cursor.
- `Actions`: AirDrop (`NSSharingService(named: .sendViaAirDrop)`), Float, Copy (`NSPasteboard` file URLs), Move (`NSOpenPanel` choose dir → move, collision-safe), Copy Path (newline-joined POSIX paths), Terminal (`open -a Terminal <dir>`).
- `FloatShelf`: always-on-top panel per float group with file chips (QuickLook thumbnails via `QLThumbnailGenerator`); chips are drag sources (`NSDraggingSource`, copy op); shelf accepts drops → callback to open wheel; close button; position remembered.
- Tests: path-joining, move collision naming, settings encode/decode round-trip.

## W3 — Image + PDF engines

Targets: `ImageEngine`, `PDFEngine`. Owns `Sources/ImageEngine/**`, `Sources/PDFEngine/**`, `Tests/ImageEngineTests/**`, `Tests/PDFEngineTests/**`.
SPEC: §3 Image, PDF, Text rows; §4 Image, PDF rows (headless parts).

ImageEngine:
- Conversions among JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, GIF, SVG(in), → PDF. ImageIO first; check writable types via `CGImageDestinationCopyTypeIdentifiers()`; fall back to `magick` for WebP/AVIF write and SVG read. Preserve orientation and color profile; flatten alpha onto white for JPG/BMP.
- Tools (headless): `image.compress` (quality %, or `targetBytes` via binary search ≤8 iterations), `image.resize`, `image.metadata.strip`, `image.metadata.read` (returns JSON text output), `image.qr.read` (Vision `VNDetectBarcodesRequest` → .txt), `image.toPDF` (combine), `image.collage` (combine, grid layout options). Descriptors for `image.crop`, `image.adjust`, `image.annotate`, `image.redact`, `image.background` with `needsUI: true` plus headless `run` taking explicit options (rect, filter values, shapes, regions) for W6 to call.

PDFEngine:
- PDF → JPG/PNG (every page, 300 DPI default, folder output), → TXT, → MD (page headings), → DOCX (via `NSAttributedString` `.officeOpenXML`), → EPUB (build OPF/XHTML; zip with `mimetype` stored first uncompressed). Text (TXT) → PDF/JPG/PNG via CoreText.
- Tools: `pdf.compress` (re-render images at quality/DPI; `targetBytes` search), `pdf.merge` (combine), `pdf.split` (per page or ranges), `pdf.reorder` (needsUI, headless takes page order array + rotations + deletions), `pdf.text.extract`, `pdf.metadata.strip`.
- Tests: round-trip every advertised pair on generated fixtures; target-size compress lands within ±10%; multi-page output naming.

## W4 — Media engine (video + audio)

Target: `MediaEngine`. Owns `Sources/MediaEngine/**`, `Tests/MediaEngineTests/**`.
SPEC: §3 Video, Audio rows; §4 Video, Audio rows (headless parts).

- `FFmpeg` wrapper over `ProcessRunner`: `-progress pipe:1 -nostats`, duration from `ffprobe -show_format -of json`, progress = `out_time_us / duration`; kill on cancel; stderr tail in errors.
- Conversions: video MP4/MOV/MKV/WebM/AVI/WMV ↔ each, → GIF (palettegen two-pass, fps/width options), → MP3 (audio extract). Audio MP3/M4A/WAV/FLAC/OGG/Opus/AIFF/WMA ↔ each. Stream-copy when container change allows (`-c copy`), else sensible codecs per container; use `h264_videotoolbox`/`hevc_videotoolbox` when `ffmpeg -encoders` lists them, fallback libx264.
- Tools: `video.compress` (percent → CRF/bitrate mapping; `targetBytes` → two-pass bitrate from duration minus audio), `video.trim`, `video.crop`, `video.speed` (setpts + atempo chain), `video.split` (ranges or N parts), `video.join` (combine; concat demuxer when codecs match, else re-encode), `video.snapshot` (time → PNG), `video.audio.extract`, `media.metadata.strip` (`-map_metadata -1`), `audio.compress`, `audio.normalize` (two-pass `loudnorm`), `audio.trim`, `audio.bleep` (ranges → mute + sine overlay), `audio.channels` (mono/stereo/swap). UI-bound tools (`video.trim`, `video.crop`, `video.split`, `video.snapshot`, `audio.trim`, `audio.bleep`) get `needsUI: true` but work headless with explicit options.
- Gate capabilities on `ffmpeg`/`ffprobe` presence and encoder list.
- Tests: each pair on 2-second testsrc/sine fixtures; output validated by ffprobe codec/duration; progress monotonic; cancel leaves no output file.

## W5 — Document engines (docs, subtitles, archives, spreadsheets, slides)

Target: `DocEngine`. Owns `Sources/DocEngine/**`, `Tests/DocEngineTests/**`.
SPEC: §3 Documents, Slides, Spreadsheets, Subtitles, Archives rows.

- Documents: DOCX/DOC/RTF/RTFD/TXT/HTML/ODT/text clippings → DOCX/TXT/HTML/RTF/MD/PDF/EPUB. Use `NSAttributedString` document types and `/usr/bin/textutil`; MD in via `AttributedString(markdown:)`; MD out via attribute walk (headings, bold/italic, lists, links); PDF out via CoreText pagination (Letter/A4 from Locale); EPUB out shares a small builder (own copy here — don't import PDFEngine). PAGES/EPUB input: v2, don't advertise.
- Subtitles: SRT ↔ VTT, → TXT (strip timing/tags); tolerant parser (BOM, CRLF, missing indices).
- Archives: folder/file → ZIP (`ditto -c -k --sequesterRsrc --keepParent`), TAR, TAR.GZ; extract ZIP/TAR/GZ/RAR → folder (`/usr/bin/tar -xf` handles RAR via libarchive; gate RAR on a probe). Guard against path traversal on extract.
- Spreadsheets: CSV ↔ TSV (RFC 4180 quoting); XLSX read (unzip → `sharedStrings.xml` + `sheet1.xml` via `XMLParser`) → CSV/TSV; CSV → XLSX minimal OOXML writer; table → PDF via CoreText grid. ODS/XLS: v2, don't advertise.
- Slides: advertise PPT/PPTX → PDF/JPG/PNG only if Keynote (AppleScript export) or `soffice --headless --convert-to` is available; else none.
- Tests: round-trips on generated fixtures; EPUB passes structural checks (mimetype first, stored); archive extract rejects `../` entries; CSV quoting edge cases.

---

## W6 — Image editor window (P5)

Target: `ImageEditorUI` (deps: RondoKit, ImageEngine). Owns `Sources/ImageEditorUI/**`, `Tests/ImageEditorUITests/**`.
SwiftUI window: canvas with zoom/pan; Crop (free/aspect presets, rotate/flip), Adjust (exposure, contrast, saturation, warmth, sharpness via Core Image, live preview), Annotate (arrow, rect, ellipse, freehand, text; color/width), Redact (box, blur, pixelate regions), Background (solid color/padding for transparent images). Save → builds `JobSpec` with explicit options and calls the provided submit closure; never writes files itself. Entry: `ImageEditor.open(url:submit:)`.

## W7 — Media editor window (P5)

Target: `MediaEditorUI` (deps: RondoKit, MediaEngine). Owns `Sources/MediaEditorUI/**`, `Tests/MediaEditorUITests/**`.
AVKit player + filmstrip/waveform timeline; Trim (in/out handles), Split (markers), Crop (overlay rect, aspect presets), Snapshot (current frame), Speed slider, Audio Bleep (mark ranges on waveform). Output → `JobSpec` via submit closure. Entry: `MediaEditor.open(url:tool:submit:)`.

## W8 — PDF organizer (P5)

Target: `PDFOrganizerUI` (deps: RondoKit, PDFEngine). Owns `Sources/PDFOrganizerUI/**`, `Tests/PDFOrganizerUITests/**`.
Thumbnail grid (`PDFKit` thumbnails): drag-reorder, rotate, delete, multi-select split ranges, merge multiple dropped PDFs, images → PDF with page size/margins. Output → `JobSpec` via submit closure. Entry: `PDFOrganizer.open(urls:tool:submit:)`.
