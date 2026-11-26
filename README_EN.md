<div align="center">

# MSnip `v0.9.2`

**Precision screenshots, desktop pins, a top-edge drop shelf, scrolling capture, high-frame-rate recording, offline OCR, and in-place translation — packed into a ~3.5 MB pure-native Swift app. Zero dependencies, MIT open source, no subscriptions.**

[简体中文](README.md) · [English](README_EN.md)

[![macOS](https://img.shields.io/badge/macOS-12.0%2B-0C6EF3?style=flat-square&logo=apple&logoColor=white)](https://github.com/xy-tuoren/MSnip)
[![Swift](https://img.shields.io/badge/Pure_Native-Swift_5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](Package.swift)
[![Zero Dependencies](https://img.shields.io/badge/Third--Party_Deps-0-10B981?style=flat-square)](Package.swift)
[![Bundle Size](https://img.shields.io/badge/App_Size-~3.5_MB-6366F1?style=flat-square)](scripts/bundle.sh)
[![License](https://img.shields.io/badge/License-MIT-64748B?style=flat-square)](LICENSE)

</div>

<br/>

![MSnip Overview](docs/msnip-showcase.jpg)

---

## Why Switch to MSnip?

Many macOS power users end up running 3–4 separate menu bar utilities just to cover daily visual work: one for screenshots and annotation, one for desktop pinning, one for scrolling capture or screen recording, and another for OCR and translation. **MSnip brings the entire workflow into a single ~3.5 MB native Swift app — fast, inspectable, and free forever.**

- **One ~3.5 MB App Replaces Multiple Utilities**: Capture, 12 annotation tools, floating pins, vertical & horizontal scrolling capture, high-frame-rate GIF/MP4 recording, offline OCR & table extraction, LaTeX formulas, and multi-engine in-place translation — MIT licensed with no accounts, no watermarks, and no paywalls.
- **Built for Developers & AI Coding Workflows**:
  - **Smart Terminal & AI IDE Paste**: Copy any screenshot and press `⌘V` inside standalone terminals or embedded IDE terminals (VS Code / Cursor / Zed / JetBrains) to automatically paste a space-free temporary `.png` file path ready for CLI tools and AI assistants — while still pasting clean raw images into chat apps and files into Finder.
  - **1-Click Offline Auto-Redact**: On-device Vision scans your selection and masks API keys/JWTs, emails, phone numbers, 18-digit IDs, non-loopback IPv4 addresses, and bank cards in one undoable step before you share a screenshot.
  - **Instant Markdown & TSV Tables**: Extract structured tables straight into Markdown or spreadsheet columns (Excel / Numbers).
- **True Native Performance, Not a Heavy Wrapper**: Zero third-party packages, no Electron, no WebView shell, no bundled `ffmpeg`. **0% idle CPU**, immediate memory release after every capture or recording session, hardware-accelerated pipelines, and smooth high-frame-rate interaction.
- **Privacy You Can Actually Verify**: Screenshot apps hold macOS's highest-trust *Screen Recording* permission. MSnip is 100% open source with zero external dependencies; capturing, annotation, redaction, OCR, QR/barcode scanning, scrolling stitch, recording, and macOS 15+ Apple native translation all run **entirely on-device**. Optional cloud translation/formula keys stay isolated in `0600` local files or macOS Keychain.

---

## How MSnip Compares

| Capability | Built-in macOS | Typical Lightweight Tools | Commercial All-in-One Suites | **MSnip** |
| :--- | :---: | :---: | :---: | :---: |
| License & Pricing | Built-in | Free or paid (mostly closed) | Paid or subscription (closed) | **Free · MIT Open Source** |
| App Size & Dependencies | Built-in | 10–60 MB | 50–250 MB (often bundled runtimes) | **~3.5 MB · 0 External Deps** |
| Idle Footprint & Memory | Light | Light | Higher resident memory | **0% Idle CPU · Zero Memory Retention** |
| Annotation & Auto-Redact | Basic markup | Strong markup, rare auto-redact | Full markup | **12 Tools + Offline Auto-Redact** |
| Desktop Pinning & Compare | None | Basic pin | Partial | **Luminous Glow + 8-Way Resize + Live Text + Multi-Image Collage** |
| Scrolling Capture | None | Partial (usually vertical only) | Supported | **Vertical & Horizontal + Undo Step + Sticky Bar Rejection** |
| High-FPS Recording & Audio | Basic only | Often missing or capped | Supported | **High-FPS Hardware H.264 + System Audio + Live Draw + Lossless Trim** |
| Offline OCR / Translation / LaTeX | Preview only | Basic OCR only | Usually needs separate app | **OCR + Markdown Tables + In-Place Translate + LaTeX** |
| Smart Terminal / AI IDE Path Paste | None | None | None | **Context-Aware (Path in Terminals / Raw Image in Chat)** |

---

## Performance Advantages

MSnip is built strictly on Apple's system frameworks so speed and efficiency show up in every interaction:

- **~3.5 MB Footprint & Instant Trigger**: No cross-platform runtime or embedded binary bloat — pressing a hotkey freezes the screen almost instantaneously.
- **0% Idle CPU & Zero Memory Retention**: At rest, MSnip stays a tiny menu bar citizen. As soon as a capture, pin, or recording session closes, full-screen bitmaps, slice caches, and temporary buffers are freed immediately — no memory creep over days of uptime.
- **Smooth High-Frame-Rate Interaction**: The frozen canvas is backed by a static GPU layer with dirty-rect partial redraws and a zero-copy pixel loupe, keeping selection dragging, eyedropper inspection, and markup fluid on high-refresh-rate displays.
- **Hardware-Accelerated Encoding & Low-Memory Recording**: MP4 capture streams directly through macOS's zero-copy hardware H.264 pipeline at **high frame rates** (matching your display's refresh rate) without bogging down active apps; GIF recording spools compressed LZ4 frames to disk to avoid RAM spikes; Gaussian blur runs on SIMD vector acceleration.
- **Pixel-Exact Retina & Wide-Gamut Accuracy**: Interaction coordinates and physical pixel output stay strictly decoupled, preserving native Display P3 / ICC color profiles end-to-end with zero washed-out colors or blurry text.

---

## Core Capabilities

### 1. Precision Capture, Custom Delay & Instant Fullscreen
- **Smart Element Snapping**: Automatically detects Dock items, menu bar items, window layers, UI accessibility controls, and closed visual edges. Scroll or press `[` / `]` before locking to step cleanly between *UI element ↔ parent container ↔ full window*.
- **Custom Delayed Capture (`⌥W`, `1–60s`)**: Floating countdown ring (click to capture immediately; press `Esc` or the same hotkey to cancel) with modal-menu focus guarding so open dropdown menus and hover states capture cleanly without hanging.
- **Instant Fullscreen Capture (`⌥S`)**: Immediately captures the display under your cursor with configurable default behavior (**Copy / Save / Copy & Save**).
- **Isolated Clean Window Capture (`F` / `⇧↩`)**: Strips desktop clutter and exports a single window with native macOS transparent drop shadow.
- **Corner Radius & Luminous Glow (`B` / `G`)**: Drag or scroll the two top-right side pills to tune `0%–100%` rounded corners and soft luminous outer glow live.
- **Multi-Format Export & Custom Filenames**: Auto-probes hardware-supported `PNG / JPG / HEIC / AVIF / BMP / TIFF`, supports Retina `1×` downscaling, customizable filename templates (`MSnip-{date}-{time}-{w}x{h}`), and subtle audio feedback.

### 2. 12 Annotation Tools, Spotlight & Offline Auto-Redact
- **Complete Toolkit**: Rectangle, Ellipse, Arrow, Line, Bézier Pen, Highlighter, auto-incrementing Step badges `①②③`, Mosaic, SIMD Gaussian Blur, **Spotlight highlight**, Capsule Text, and segmented Eraser.
- **1-Click Offline Auto-Redact**: Detects and masks API keys/JWTs, emails, phone numbers, 18-digit IDs, non-loopback IPv4 addresses, and bank cards locally — undoable in one `⌘Z`.
- **Post-Edit Handles, `⌘C/⌘V/⌘D` Cloning & 100-Step Undo**: Select any shape to adjust corners, endpoints, or step tails; press **`⌘C` / `⌘V`** to copy-paste or **`⌘D`** to duplicate in place (duplicating step badge `①` automatically increments to `②`), backed by a 100-step Copy-on-Write Undo/Redo stack.

### 3. Desktop Pin Workflow, Top Shelf & Collage Studio
- **Compact Top Drop Shelf (MSnip Shelf)**: Supports **Hover to Expand** (strict top-edge `≤ 1.5pt` `0.55s` dwell anti-misfire, `80ms` instant open when dragging files, silent capture recording without auto-popping, click top bar to dismiss), **Hotkey Toggle**, and **Always Shown** modes. At just `98pt` tall with adaptive width (up to 9 cards at once), it supports mouse-wheel horizontal scrolling, click-to-copy, 1-click `✎` annotate, `⌘ + Click` ordered multi-select for collage, drag-out sharing, per-card deletion, and `+ Clipboard`. Menu bar icon supports **Left-Click to open Settings, Right-Click for the action menu**.
- **Soft Luminous Outer Glow**: Subtle white halo at rest (clear contrast on both dark and light wallpapers) transitioning smoothly to a soft blue glow on hover or focus; tuned via a continuous `0%–100%` slider in Settings with live pin preview, bidirectionally synced with the selection glow slider and `⌥ + Scroll` on pins.
- **8-Way Clean Edge & Corner Resizing**: Completely uncluttered at rest; hovering the outer luminous border or any of the 4 corners reveals subtle directional indicators with native macOS resize cursors and aspect-locked scaling.
- **Multi-Image Collage & PDF Merge Studio**: Open from the Top Shelf (with optional `⌘ + Click` multi-select) or Recent Captures menu. Supports drag-in, add from clipboard/history, reordering, and **embedded in-window annotation editing** for both single images and the stitched collage (preserving vector edits with 1-click reset). Provides two clear modes — **Stitch Image** (Horizontal / Vertical / 2–4 Col Grid, Fill/Center/Top alignment, Auto/16:9/4:3/1:1 aspect presets, live gap/padding/corner radius/card shadow, 2D color picker + screen eyedropper/gradients/transparent backdrop, step badges & watermarks) and **Merge Multi-Page PDF** (lossless native CoreGraphics multi-page `.pdf` export with live margin & page number preview). Oversized collages and long captures auto-scale to fit inside screen bounds while preserving full-resolution pixels underneath.
- **Unobstructed Floating Bar**: `[ ✥ Drag | ✎ Annotate | OCR | Translate | Copy | ↓ Save | ✕ Close ]` sits outside the image. Includes native Live Text selection directly on the pin, `⌘ + Drag` out as a `.png` file, 1-click `↓` quick-save (`⇧ + Click` Save As), Crop (`C`), Rotate (`R`), Flip (`H`), Click-Through Ghost Mode (`P`), and `8pt` magnetic snapping.

### 4. Vertical & Horizontal Scrolling Capture (`⌥E` / `L`)
- Lossless live frame sampling that strips sticky headers, footers, and static sidebars — supporting both **Vertical Down** and **Horizontal Right** stitching, **`⌘Z` undo last stitch**, automatic desync recovery, and 1-click handoff to Pin Annotation.

### 5. High-Frame-Rate Region Recording — GIF & MP4 (`⌥R` / `V`)
- **High Frame Rate & 3 Quality Tiers**: MP4 offers **Standard (`≤1280px`) / HD (`≤1920px`) / Original (Retina 1:1)** at **30fps / 60fps / Native High Refresh Rate** with FPS-adaptive bitrate; GIF offers **Compact (`720px`) / Standard (`960px`) / HD (`1280px`)**.
- **System Audio + Live Annotation + Lossless Trim**: Includes **macOS 13+ native system audio capture**, click ripples, modifier key HUD, **real-time laser/pen drawing during recording**, and lossless MP4 head/tail trimming.

### 6. Offline OCR (with Silent Copy), Tables, QR/Barcode, LaTeX & Multi-Engine Translation (`⌥F` / `⌥D`)
- **3 OCR Modes (In-Place Live Text / Dual-Pane / Silent Copy)**: Select text directly on the frozen canvas, open the dual-pane inspector, or switch to **Silent Copy** (dismisses overlay immediately on release and copies recognized text in the background without popping up a window); copy structured tables as **Markdown** or **TSV**.
- **Silent QR & Barcode Detection**: Scans locked selections in the background for 1-click Open URL or Copy Value.
- **Paragraph In-Place & Streaming Translation**: Groups natural paragraphs and renders translations back in place (hold to peek original; right-click to switch language). Supports **macOS 15+ Apple Offline Translation**, plus OpenAI, Claude, Gemini, DeepSeek, Tencent, Baidu, Youdao, DeepL, and custom Webhooks with primary/fallback failover.
- **LaTeX Formula Recognition**: Vision LLMs, SimpleTex, and Mathpix with built-in offline native WebKit MathML rendering and online KaTeX progressive enhancement.

### 7. Customizable Shortcuts, CLI & `msnip://` URL Scheme
- Adaptive Light / Dark / System appearance, 12 customizable global hotkeys + 24 single-key canvas bindings, system/app conflict scanner, optional priority hotkey takeover, secret-stripped JSON config import/export, and 1-click diagnostic reports.
- **CLI & `msnip://` URL Scheme Automation** (Raycast / Alfred / Apple Shortcuts): Trigger any workflow via `open msnip://capture`, `msnip://ocr`, `msnip://silent-ocr`, `msnip://shelf`, `msnip://long`, `msnip://record`, `msnip://pin`, `msnip://translate`, or `MSnip --enter=ocr|shelf|long|video|pin` with instant single-instance IPC handoff.

---

## Installation

### Requirements
- **macOS 12.0 (Monterey) or later** (Apple Silicon `arm64` & Intel `x86_64`)
  - Live Text & MP4 native system audio capture: macOS 13.0+
  - `ScreenCaptureKit` fast silent capture: macOS 14.0+ (automatic fallback on macOS 12–13)
  - Apple native offline translation: macOS 15.0+
- **Permissions**:
  - **Screen Recording** (Required): Capturing displays and recording screen regions.
  - **Accessibility** (Optional): UI-control snapping, IDE terminal focus detection, and priority hotkey takeover.

### Option 1: Build & Install from Source to `/Applications` (Recommended)

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/xy-tuoren/MSnip.git
cd MSnip
bash scripts/install.sh --rebuild
```

> [!TIP]
> If you rebuild from source frequently, run `bash scripts/setup-cert.sh` once to create a persistent local signing certificate in your Keychain — future rebuilds keep macOS Screen Recording and Accessibility permissions intact without re-granting.

### Option 2: Homebrew Cask

```bash
brew tap xy-tuoren/msnip https://github.com/xy-tuoren/MSnip
brew install --cask msnip
```

---

## Keyboard Shortcuts

### Global Hotkeys (4 Built-in Presets + Full Custom Recording)

| Action | Left-Hand (Default) | Number Keys | Function Keys | Classic 3-Key |
| :--- | :---: | :---: | :---: | :---: |
| **Area Capture** | `⌥A` | `⌃1` | `F1` | `⌃⌘A` |
| **Pin to Desktop** | `⌥T` | `⌃2` | `F2` | `⌃⌘T` |
| **Capture Fullscreen** | `⌥S` | `⌃3` | `F3` | `⌃⌘S` |
| **Translate Selection** | `⌥D` | `⌃4` | `F4` | `⌃⌘D` |
| **Scrolling Long Capture** | `⌥E` | `⌃5` | `F5` | `⌃⌘E` |
| **Region Recording (GIF/MP4)** | `⌥R` | `⌃6` | `F6` | `⌃⌘R` |
| **Delayed Capture** | `⌥W` | `⌃7` | `F7` | `⌃⌘W` |
| **Quick OCR** | `⌥F` | `⌃8` | `F8` | `⌃⌘G` |
| **Top Drop Shelf** | `⌥Q` | `⌃9` | `F9` | `⌃⌘K` |
| LaTeX / Toggle Pins / Repeat Last Area | Optional | Optional | Optional | Optional |

<details>
<summary><b>Expand: All Capture Overlay & Desktop Pin Shortcuts</b></summary>

#### Inside Capture Overlay (All 24 Single Keys Customizable)

| Key / Gesture | Action |
| :--- | :--- |
| Move / Scroll / `[` `]` | Smart snap between UI element, parent container & full window |
| `Enter` / `C` / Double-Click | Copy image to clipboard (`⇧⌘C` / `⌥↩` forces temporary file path) |
| `S` / `⌘S` (`⇧` for Save As) | Quick-save to default folder / Save As dialog |
| `P` | Pin selection to desktop |
| `F` / `⇧↩` (`⌥` isolated window) | Snap to window / capture isolated window with native shadow |
| `B` / `G` (or scroll side pills) | Adjust corner radius / luminous glow strength (`⌥` resets to `0%`) |
| `1`–`9` / `R` `A` `D` `W` `N` `M` `E` | Rect/Ellipse, Arrow, Pen/Highlighter, Text, Step, Mosaic/Blur, Spotlight, Eraser |
| `T` / `⇧T` / `Y` | In-place OCR / LaTeX Formula / Paragraph In-Place Translation (`⌥` dual-pane) |
| `L` / `V` | Scrolling Capture / Region Recording mode |
| `Z` / `X` / `I` / `Tab` | 4-way Pixel Caliper / Copy Coordinates / Eyedropper / Cycle Color Format |

#### Inside Desktop Pin Window

| Key / Gesture | Action |
| :--- | :--- |
| Drag any of 4 corners or 4 edges | 8-way aspect-locked resize with native macOS resize cursors |
| Scroll / `⌘+Scroll` / `⌥+Scroll` | Zoom / Adjust opacity / Tune luminous outer glow strength |
| Select text / Drag / `⌥+Drag` | Live Text selection; `8pt` magnetic snap to edges & sibling pins (`⌥` disables) |
| `⌘ + Left-Drag` | Drag out as a high-DPI `.png` file into chat, browser, or Finder |
| `⌘S` / `⇧⌘S` / Hover Bar `↓` | Quick-save to default folder / Save As (`⇧ + Click`) |
| `E` / `C` / `R` / `H` / `P` | Annotate / Crop / Rotate 90° CW / Flip Horizontal / Click-Through Ghost Mode |
| `T` / `Y` / `Esc` or Double-Click | Extract Text / Translate Text / Close Pin |

</details>

---

## Architecture & Testing

MSnip enforces strict modularity and zero-dependency hygiene in CI: every `.swift` source file is gated at `≤ 300` lines, core algorithms are decoupled from AppKit UI, and the repo ships with a zero-dependency unit test suite (**347 assertions**).

```bash
swift run MSnipTests   # Run all 347 zero-dependency core unit test assertions
```

```text
Sources/
├── MSnipCore/      # Pure algorithms & models (geometry, annotations, vImage renderer, scroll stitcher, GIF/MP4 encoder, OCR formatters, hotkey conflict engine, credential vault)
├── MSnip/          # macOS AppKit layer (menu bar, ScreenCaptureKit capture, frozen overlay, pin pool, recorder, OCR/LaTeX, translation & settings UI)
└── MSnipTests/     # Zero-dependency automated test suite (326 assertions)
scripts/
├── bundle.sh       # <=300-line gate, Release -Osize build, vector .icns icon generator & code signing
├── install.sh      # One-command install & launch to /Applications/MSnip.app
└── setup-cert.sh   # Local persistent signing certificate helper (keeps TCC permissions across rebuilds)
```

---

## License

[MIT License](LICENSE)
