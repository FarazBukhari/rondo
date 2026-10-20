# Rondo — Feature Spec (clean-room)

Target: behavior parity with *Tangerine: File Converter* (Leap Studio, Mac App Store id6813034065) as described publicly, rebuilt as an original app that runs on Intel + Apple Silicon Macs, macOS 13+.

Out of scope: free-tier limit / IAP, App Store sandbox + distribution, touch-screen gestures, any Tangerine asset or copy.

## Source map

| ID | Source | Fetched | Trust |
|----|--------|---------|-------|
| S1 | App Store listing — apps.apple.com/us/app/tangerine-file-converter/id6813034065 (v2.0.1) | 2026-10-20 | Official |
| S2 | Vendor site — tangerineformac.com | 2026-10-20 | Official |
| S3 | MacGeneration review — macg.co, Oct 2026 | 2026-10-20 | Press, hands-on |
| S4 | chatgate.ai listing (cites press kit) | 2026-10-20 | Secondary |

Tags used below: **[V]** stated by an official source (S1/S2) · **[P]** press only (S3/S4) · **[D]** our design decision (no public info) · **[STALE?]** likely to drift between app versions.

## 1. Core interaction

| # | Behavior | Tag |
|---|----------|-----|
| 1.1 | Lives in menu bar; no Dock icon (`LSUIElement`). | [V] S1 · menu contents [D] |
| 1.2 | While dragging file(s) from Finder (or anywhere), tapping a modifier opens a radial wheel at the cursor. | [V] S1 S2 |
| 1.3 | Wheel kinds: **Convert** (output formats for the dragged type), **Tools** (operations for that type), **Actions** (file actions, any file/folder). | [V] S1 S2 |
| 1.4 | Default keys: Shift → Convert, Option → Tools, Control → Actions. All remappable in Settings. | Remappable [V] S2 · defaults [D] — sources conflict (S1: Option+Shift, S2: Command, S3: Shift+Option, S4: Option) |
| 1.5 | Wheel stays open after the key is released, until drop or cancel. | [V] S2 |
| 1.6 | Drop on a slice → run; drop outside / Esc → cancel. Arrow keys move selection, Enter applies. | [V] S2 · [P] S4 |
| 1.7 | Slices depend on file type; batch drag shows only options valid for **all** dragged files. | type-dependent [V] S1 S3 · intersection rule [D] |
| 1.8 | Output = new copy beside the original; original never modified. | [V] S1 · [P] S4 |
| 1.9 | Collision naming `name 2.ext`, `name 3.ext`; multi-file outputs (PDF pages, splits) go in folder `name (pages)/`. | [D] |
| 1.10 | Each job shows a progress window; on completion results are revealed in Finder. | [V] S1 · window design [D] |
| 1.11 | Keyboard alternative without dragging: global hotkey (default ⌃⌥Space) acts on Finder selection, opens wheel in click mode. | Exists [V] S2 ("press Enter on a file…") · mechanism [D] |
| 1.12 | All processing local; no network calls. | [V] S1 S2 |
| 1.13 | Wheel opens fast (reviewer saw micro-lag on M1 — we target <100 ms on Intel). | [P] S3 · target [D] |

Fallback entry points (if global drag detection proves unreliable, see ARCHITECTURE §Risks): drop on menu-bar icon, drop on Float shelf, hotkey, Finder Quick Action. All open the same wheel. [D]

## 2. Actions wheel (6 actions, any file/folder, mixed selections OK) — [V] S1 S2

| Action | Behavior |
|--------|----------|
| AirDrop | Share via AirDrop sheet. |
| Float | Park file(s) in an always-on-top floating shelf; drag out later. Details [D]. |
| Copy | Put file(s) on the clipboard (paste in Finder copies them). |
| Move | Pick a destination folder, move file(s). |
| Copy Path | POSIX path(s), newline-joined. |
| Terminal | Open Terminal at the file's folder. |

## 3. Convert wheel — format matrix

Official counts: 275 conversion options, 26 tools, 6 actions (S2) **[STALE?]** — S4 quoted 188/25 weeks earlier.

| Kind | Inputs | Outputs | Tag | v1 engine plan [D] |
|------|--------|---------|-----|--------------------|
| Image | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, GIF, SVG (input only) | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, GIF, PDF | [V] S1 S2 | ImageIO; `magick` for WebP/AVIF write + SVG read when ImageIO can't |
| Image → doc | image | DOCX | [P] S4 | v2 |
| Video | MP4, MOV, MKV, WebM, AVI, WMV | same set + GIF + MP3 (audio extract) | [V] S1 S2 | ffmpeg (VideoToolbox H.264/HEVC when available) |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | same set | [V] S1 S2 (WMA S2/S3) | ffmpeg |
| PDF | PDF | JPG, PNG (all pages, 300 DPI), TXT, MD, DOCX, EPUB | [V] S2 | PDFKit render/text; DOCX via NSAttributedString; EPUB built in-house |
| PDF → office | PDF | PAGES, PPTX, XLSX | [V] S2 | v2 |
| Documents | DOCX, DOC, RTF, RTFD, TXT, MD, HTML, ODT, text clippings, EPUB, PAGES | DOCX, TXT, MD, HTML, RTF, PDF, EPUB | [V] S2 | `textutil` / NSAttributedString; MD via Foundation `AttributedString(markdown:)`; PAGES/EPUB input v2 |
| Slides | PPT, PPTX | PDF, JPG, PNG | [V] S2 | Optional: Keynote AppleScript or `soffice` if present; else hidden |
| Spreadsheets | XLSX, ODS, CSV, TSV, XLS (input only) | XLSX, CSV, TSV, PDF | [V] S2 | CSV/TSV + minimal XLSX read/write in Swift; ODS/XLS v2 |
| Subtitles | SRT, VTT | SRT, VTT, TXT | [V] S1 S2 | Pure Swift |
| Archives | ZIP, TAR, GZIP, RAR (input only) | ZIP, TAR, GZIP, extract to folder | [V] S1 S2 | `ditto`, `/usr/bin/tar` (bsdtar reads RAR), `gzip` |
| Text | TXT | PDF, JPG, PNG | [P] S4 | CoreText render |

## 4. Tools wheel

| Kind | Tools | Tag | UI? [D] |
|------|-------|-----|---------|
| Image | Compress (quality % or exact target size), Resize, Crop, Adjust, Annotate, Redact, Read/Edit/Remove metadata, Read QR code, Images → PDF, Collage, Add background | [V] S1 (bg: [P] S4 press kit) | Crop/Adjust/Annotate/Redact/Collage/Background → editor window; rest headless |
| Video | Compress (% or target size), Trim, Crop, Change speed, Split, Join, Snapshot, Extract audio, Remove metadata | [V] S1 · [P] S3 | Trim/Crop/Split/Snapshot → editor window |
| Audio | Compress, Normalize, Trim, Bleep, Change channels, Remove metadata | [V] S1 | Trim/Bleep → editor window |
| PDF | Compress (% or target size), Merge, Split, Reorganize pages, Extract text, Remove metadata | [V] S1 · [P] S3 | Reorganize/Split → organizer window |
| Any | Show metadata | [V] S1 | panel |

Batch: per-file tools apply to each file; combining tools (Merge, Join, Collage, Images → PDF) take all files as one input. Percentage compression works per file and per batch [V] S1 (2.0).

## 5. Settings — mostly [D]

- Modifier → wheel mapping [V] S2; keyboard shortcuts customizable [P] S3
- Default quality per kind (JPEG/HEIC quality, video CRF/preset, audio bitrate) [P] S3
- Output destination: beside original (default) | fixed folder
- Global hotkey; launch at login (`SMAppService`)
- External tool paths (ffmpeg, magick, soffice) with detected status
- Permissions status + "Open System Settings" buttons (Accessibility, Automation)

## 6. Non-functional [D]

- macOS 13+, `x86_64` primary (this Mac), `arm64` when built on Apple Silicon.
- No network; no analytics.
- Cancellable jobs; no partial files left beside originals.
- Heavy jobs (video) max 2 concurrent; light jobs up to CPU count.
