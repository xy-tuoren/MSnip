<div align="center">

# MSnip

### A Sub-3 MB Pure-Native macOS Screenshot, Annotation, Pin, Recorder, OCR & Translation Utility

**Only `2.6 MB` native (`1.3 MB` zipped), zero third-party dependencies, `0%` idle CPU, and zero idle bitmap retention — packing 12 annotation tools, offline privacy auto-redaction, desktop pins, a top drop shelf, vertical & horizontal scrolling capture, high-FPS recording, multi-engine OCR/LaTeX, and in-place translation into one MIT open-source Swift app.**

<p align="center">
  <a href="https://github.com/xy-tuoren/MSnip/releases"><img alt="Release" src="https://img.shields.io/github/v/release/xy-tuoren/MSnip?style=flat-square&label=release&color=0C6EF3"></a>
  <a href="https://github.com/xy-tuoren/MSnip/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/xy-tuoren/MSnip/ci.yml?style=flat-square&label=CI"></a>
  <a href="https://github.com/xy-tuoren/MSnip/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/xy-tuoren/MSnip?style=flat-square&color=E3B341"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-12.0%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="Native Size" src="https://img.shields.io/badge/Native_App-2.6_MB-6366F1?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Pure_Native-Swift_5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Zero Dependencies" src="https://img.shields.io/badge/3rd--Party_Deps-0-10B981?style=flat-square">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-64748B?style=flat-square"></a>
</p>

[简体中文](README.md) · **English**

**[Why MSnip](#-why-msnip) · [Comparison](#-comparison) · [Performance Budget](#-performance-budget-measured) · [Screenshots](#-screenshots) · [Core Features](#-core-capabilities) · [Installation](#-installation) · [Shortcuts](#-keyboard-shortcuts) · [Architecture](#-architecture--testing)**

</div>

<br/>

![MSnip Capture Overlay: frozen screen, 12 annotation tools, offline privacy redaction, and pixel magnifier](docs/msnip-hero.jpg)

*Pressing `⌥A`: instant frozen canvas, smart window/control snapping, dual-layer floating toolbar, 1-click offline redaction of API keys / emails / phone numbers, live corner radius & luminous glow pills, and a zero-copy 15×7 GPU pixel loupe.*

---

## Why MSnip?

Most macOS power users end up running 3–4 menu bar utilities just to cover everyday visual workflows (screenshots + pins + recording/scrolling + OCR/translation), paying yearly subscriptions for closed-source suites, or carrying 100+ MB Electron/Qt wrappers with bundled `ffmpeg`.

**MSnip refuses to trade power for lightness**: zero external packages, written strictly in native Swift, weighing just **2.6 MB** as a native build — fast, inspectable, and MIT open source forever.

- **One App Replaces Four, Open & Uncluttered**: Screenshots, 12 annotation tools, offline auto-redact, desktop pins, top drop shelf, multi-image collage & PDF merge, vertical & horizontal scrolling capture, high-FPS GIF/MP4 recording (with system audio), multi-engine OCR/tables, LaTeX formulas, and in-place translation — no accounts, no watermarks, no paywalls.
- **Built for Developers & AI Coding Workflows**:
  - **Smart Terminal & AI IDE Paste**: Copy a screenshot and press `⌘V` in standalone terminals or embedded IDE terminals (VS Code / Cursor / Zed / JetBrains / Claude Code / Codex) to automatically paste a space-free temporary `.png` file path — while still pasting raw images into chat apps and files into Finder.
  - **1-Click Offline Privacy Auto-Redact**: On-device Vision locates and masks API keys/JWTs, emails, phone numbers, 18-digit IDs, non-loopback IPv4 addresses, and bank cards in one undoable step.
  - **Instant Markdown & TSV Tables**: Extract multi-column tables straight into Markdown or Excel / Numbers columns.
- **Verifiable Local-First Privacy**: Screenshot tools hold macOS's highest-trust *Screen Recording* permission. MSnip is 100% open source; capture, annotation, auto-redact, OCR, QR/barcode scanning, scrolling stitch, recording, and macOS 15+ Apple native translation all run **entirely on-device**. Optional cloud translation/OCR keys stay isolated in `0600` local files or macOS Keychain.

---

## Comparison

> Summarized from publicly documented capabilities across popular macOS screenshot tools.

| Capability | Built-in macOS | Shottr | Snipaste | CleanShot X | PixPin | **MSnip** |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **License & Pricing** | Built-in | Free / Paid Pro (Closed) | Free / Paid Pro (Closed) | $29 + Renewals (Closed) | Free / Subscription (Closed) | **Free Forever · MIT Open Source** |
| **Stack & Dependencies** | Built-in | Native Swift | Qt / C++ | Native Swift + Closed SDKs | Qt / C++ + External Engines | **Pure Native Swift · 0 External Deps** |
| **App Footprint** | Built-in | ~10 MB | ~55 MB | ~50+ MB | ~120+ MB | **Native `2.6 MB` (Universal `6.0 MB`)** |
| **Annotations & Auto-Redact** | Basic | Rich markup | Rich markup | Rich + manual redact | Rich markup | **12 Tools + Offline Auto-Redact** |
| **Desktop Pinning** | None | Single-image pin | Strong pin | Supported | Strong pin | **Luminous Glow + 8-Way Resize + Live Text + Ghost Mode** |
| **Top Drop Shelf & Collage/PDF** | None | None | None | None | None | **98pt Top Shelf + Multi-Image Collage + PDF Merge** |
| **Scrolling Capture** | None | Vertical only | None | Vertical only | Supported | **Vertical & Horizontal + Undo Step + Sticky Bar Rejection** |
| **High-FPS Recording & Audio** | Basic | None | None | Paid | GIF / Video | **High-FPS Hardware H.264 + System Audio + Live Draw + Lossless Trim** |
| **OCR / Tables / Translate / LaTeX** | Preview only | Offline OCR | None | Offline OCR | OCR + Pin Translate | **6 OCR Engines + Markdown Tables + In-Place Translate + LaTeX** |
| **Smart Terminal / AI IDE Paste** | None | None | None | None | None | **Context-Aware (Path in Terminals / Raw Image in Chat)** |

---

## Performance Budget (Measured)

| Metric | Measured Result | Engineering Notes |
| :--- | :--- | :--- |
| **Native App Bundle (`arm64`)** | **`2.6 MB`** (`1.3 MB` zipped) | `2,696 KB` via `scripts/bundle.sh` (hard gate `≤ 3.0 MiB`) |
| **Universal Bundle (`arm64` + `x86_64`)** | **`6.0 MB`** (`2.8 MB` zipped) | Dual-arch Universal Binary for GitHub Releases & Homebrew |
| **App Icon (`AppIcon.icns`)** | **`64 KB`** | Pure CoreGraphics vector + adaptive 5-filter `zlib-9` + 8 `sRGB` slices |
| **Idle CPU Usage** | **`0.0%`** | Strictly event-driven — zero background polling timers |
| **Post-Session Memory Retention** | **Immediate Release** | Full-screen `CGImage`, tile caches, and WebKit processes freed on close |
| **Overlay & Magnifier Rendering** | **High-Refresh Smooth** | Static GPU layer + dirty-rect partial redraws + zero-copy loupe sampling |
| **Hardware Recording Pipeline** | **60 / 120 fps** | Zero-copy VideoToolbox H.264 MP4; LZ4 disk-spooled GIF prevents RAM spikes |
| **Retina & Color Accuracy** | **Native Display P3** | Decoupled logical/physical coordinates with end-to-end display ICC preservation |

**How does MSnip stay at `2.6 MB` without cutting features or runtime safety?**
1. **Zero Third-Party Dependencies**: No Electron, no WebView shell, no Qt, no bundled `ffmpeg` — built directly on macOS `AppKit`, `ScreenCaptureKit`, `Accelerate/vImage`, `Vision`, `VideoToolbox`, and `Translation`.
2. **Whole-Module Single-Unit LLVM Optimization**: Release builds pair `-Osize` + `-cross-module-optimization` + `-enable-single-module-llvm-emission` (cross-file LLVM outlining & function merging) + `-exported_symbol _main` (trimming 165 KB from `LC_DYLD_EXPORTS_TRIE`) while **preserving full Swift reflection metadata** for 100% safe SwiftUI / `Translation` / `VisionKit` interop.
3. **Pure-Vector High-Compression Icon**: [generate-icon.swift](scripts/generate-icon.swift) renders every resolution sharply in CoreGraphics and packs a `64 KB` tagged `sRGB` `.icns` directly without raster bloat.

---

## Who Is It For?

- **Developers & AI Coding Power Users**: Copy any screenshot and `⌘V` straight into Terminal / Cursor / Claude Code / Codex as a space-free file path; auto-redact API keys and emails offline before sharing bug reports.
- **Product, Design & Technical Writers**: 12 crisp annotation tools, auto-incrementing step badges `①②③`, rounded corners & luminous borders, clean isolated window shadows, multi-image collage, and lossless multi-page PDF merge.
- **Cross-Language Readers & Researchers**: Paragraph-level in-place translation (macOS 15+ Apple offline + streaming LLMs), multi-engine OCR, Markdown table extraction, and LaTeX formula recognition.
- **Minimalists Tired of Bloat & Subscriptions**: Replace 3–4 menu bar utilities with one inspectable `2.6 MB` native Swift app.

---

## Screenshots

### Core Workflows (Desktop Pin · Top Drop Shelf & Collage · OCR / Translation / LaTeX · Developer Tools)

![MSnip Core Workflows: Desktop Pin, Top Drop Shelf & Collage Studio, Multi-Engine OCR/Translate/LaTeX, Smart Terminal Paste & High-FPS Recording](docs/msnip-workflow.jpg)

### Geek Settings Center (Live App Capture · 4 Unified Tabs · Zero Horizontal Scrollbars)

<p align="center">
  <img src="docs/msnip-settings.png" alt="MSnip Live Geek Settings Window" width="840"/>
</p>

*All preferences organized across 4 clean tabs (**General / Shortcuts / OCR & Translation / Models & Services**) with adaptive Light/Dark appearance, auto-save, optional Keychain secret storage, and sanitized JSON config export/import.*

---

## Core Capabilities

### 1. Precision Capture, Custom Delay & Instant Fullscreen
- **Smart Multi-Level Snapping**: Detects Dock items, menu bar items, windows, UI accessibility controls, and closed visual edges; scroll or press `[` / `]` to step between *UI element ↔ parent container ↔ full window*.
- **Custom Delayed Capture (`⌥W`, `1–60s`)**: Floating countdown ring (click to shoot immediately; `Esc` cancels) with modal-menu focus guards so open dropdown menus capture cleanly.
- **Instant Fullscreen Capture (`⌥S`)**: Captures the display under your cursor with configurable default action (**Copy / Save / Copy & Save**).
- **Isolated Clean Window (`F` / `⇧↩`)**: Strips desktop clutter and exports a single window with native macOS transparent shadow.
- **Corner Radius & Luminous Glow (`B` / `G`)**: Drag or scroll the top-right side pills to tune `0%–100%` rounded corners and soft outer glow live.
- **Multi-Format Export & Custom Filenames**: Auto-probes `PNG / JPG / HEIC / AVIF / BMP / TIFF`, Retina `1×` downscaling, custom filename templates (`MSnip-{date}-{time}-{w}x{h}`), and a floating Quick-Access card.

### 2. 12 Annotation Tools, Spotlight & 1-Click Offline Auto-Redact
- **Full Toolkit**: Rectangle, Ellipse, Arrow, Line, Bézier Pen, Highlighter, auto-incrementing Step badges `①②③`, Mosaic, SIMD Gaussian Blur, **Spotlight highlight**, Capsule Text, and segmented Eraser.
- **1-Click Offline Auto-Redact**: Detects and masks API keys/JWTs, emails, phone numbers, 18-digit IDs, non-loopback IPv4 addresses, and bank cards locally — undoable in one `⌘Z`.
- **Post-Edit Handles, Cloning & 100-Step Undo**: Select any shape to refine corners/endpoints; **`⌘C` / `⌘V`** copy-paste and **`⌘D`** duplicate in place (auto-incrementing step numbers), backed by a 100-step Copy-on-Write Undo/Redo stack.

### 3. Desktop Pins, Top Drop Shelf & Collage / PDF Studio
- **Compact Top Drop Shelf (MSnip Shelf)**: Supports **Hover to Expand** (strict top-edge `≤ 1.5pt` `0.55s` dwell anti-misfire, `80ms` drag-to-top reveal), **Hotkey Toggle**, and **Always Shown**; `98pt` height holding up to 9 cards with click-to-copy, `✎` annotate, `⌘ + Click` ordered multi-select for collage, and drag-out sharing. Menu bar icon opens the action menu on **left- or right-click**, with **`⌥ + Left-Click`** toggling the Top Shelf.
- **Desktop Pins**: Soft white/blue luminous outer glow synced `0%–100%` across Settings, selection overlay, and `⌥ + Scroll`; 8-way hover resizing, on-pin Live Text selection, `⌘ + Drag` out as `.png`, Click-Through Ghost Mode (`P`), `8pt` magnetic snapping, and an unobstructed floating action bar.
- **Multi-Image Collage & PDF Merge Studio**: Drag-in, reorder, **embedded in-window annotation editing**, **Stitch Image** mode (Horizontal / Vertical / 2–4 Col Grid, aspect presets, gap/padding/radius/shadow/2D color picker + eyedropper/gradients/badges/watermark), and lossless **Merge Multi-Page PDF** mode.

### 4. Vertical & Horizontal Scrolling Capture (`⌥E` / `L`) & High-FPS Recording (`⌥R` / `V`)
- **Scrolling Capture**: Lossless live sampling that rejects sticky headers, footers, and static sidebars — supporting **Vertical Down** and **Horizontal Right** stitching, **`⌘Z` undo last step**, and desync auto-recovery.
- **High-FPS GIF / MP4 Recording**: MP4 offers **Standard / HD / Original (Retina 1:1)** at **30fps / 60fps / Native High Refresh Rate**, **macOS 13+ native system audio capture**, click ripples, keystroke HUD, **live pen annotation during recording**, and **lossless MP4 head/tail trimming**; GIF offers **Compact / Standard / HD**.

### 5. Multi-Engine Translation, OCR (Offline + Cloud + Vision LLM) & LaTeX (`⌥D` / `⌥F`)
- **Paragraph In-Place & Streaming Translation**: Supports **macOS 15+ Apple Native Offline Translation**, plus **OpenAI Chat / OpenAI Responses (`/v1/responses`) / Anthropic Messages / Gemini Native** (with reasoning-block filtering) alongside DeepSeek, Zhipu, Qwen, Doubao, Kimi, Tencent, Baidu, Youdao, DeepL, Ollama, and custom relays with failover.
- **3 OCR Modes & 6 OCR Engines**: **In-Place Live Text / Dual-Pane / Silent Copy**; alongside **Apple Offline Vision**, switch freely to **Vision LLMs / Baidu / Tencent / Youdao / Custom HTTP** (compatible with Umi-OCR / PaddleOCR / RapidOCR), export tables as **Markdown / TSV**, and detect QR/barcodes silently.
- **LaTeX Formula Recognition**: Vision LLMs, SimpleTex, Mathpix, and offline fallback with instant offline native WebKit MathML rendering and online KaTeX progressive enhancement.

### 6. CLI & `msnip://` URL Scheme Automation
- Integrates seamlessly with Raycast, Alfred, Apple Shortcuts, and shell scripts via `open msnip://capture`, `msnip://translate`, `msnip://ocr`, `msnip://silent-ocr`, `msnip://shelf`, `msnip://long`, `msnip://record`, `msnip://pin`, `msnip://settings`, or `MSnip --enter=ocr|shelf|long|video|pin`.

---

## Installation

### Requirements
- **macOS 12.0 (Monterey) or later** (Apple Silicon `arm64` & Intel `x86_64`)
  - Live Text & MP4 native system audio capture: macOS 13.0+
  - `ScreenCaptureKit` fast silent capture: macOS 14.0+ (automatic fallback on macOS 12–13)
  - Apple native offline translation: macOS 15.0+
- **Permissions**: **Screen Recording** (Required for capture/recording); **Accessibility** (Optional for UI-control snapping, IDE terminal detection, and priority hotkey takeover).

### Option 1: Build & Install Native `2.6 MB` App from Source (Recommended)

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/xy-tuoren/MSnip.git
cd MSnip
bash scripts/install.sh --rebuild
```

> [!TIP]
> Run `bash scripts/setup-cert.sh` once to generate a persistent local signing certificate in your Keychain so future rebuilds preserve macOS Screen Recording and Accessibility permissions automatically.

### Option 2: Direct Download from GitHub Releases (Universal Binary)

Download `MSnip-v*-macOS.zip` from **[GitHub Releases](https://github.com/xy-tuoren/MSnip/releases)**, unzip, and move `MSnip.app` to `/Applications`.

### Option 3: Homebrew Cask

```bash
brew tap xy-tuoren/msnip https://github.com/xy-tuoren/MSnip
brew install --cask msnip
```

---

## Keyboard Shortcuts

### Global Hotkeys (4 Built-in Presets + Conflict Scanner & Custom Recording)

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

MSnip enforces cohesive modularity and zero third-party dependencies: **111 `.swift` files** gated at `≤ 800` lines in CI, pure core algorithms decoupled from AppKit UI, and a zero-dependency unit test suite (**414 assertions**).

```bash
swift build                             # Debug compile check
swift run MSnipTests                    # Run all 414 core unit test assertions
bash scripts/bundle.sh                  # Native single-arch build (2.6 MB)
bash scripts/bundle.sh --universal      # Dual-arch Universal Binary (6.0 MB, CI/Releases)
```

```text
Sources/
├── MSnipCore/      # Pure algorithms & models (geometry, 12 annotations, vImage SIMD renderer, scroll stitcher, GIF/MP4 encoder, OCR/PII detector, hotkeys & credential vault)
├── MSnip/          # macOS AppKit layer (menu bar, ScreenCaptureKit capture, frozen overlay, pin pool, shelf, collage, recorder, OCR/LaTeX, translation & settings UI)
└── MSnipTests/     # Zero-dependency automated test suite (414 assertions)
scripts/
├── bundle.sh       # <=800-line gate, Release -Osize single-unit LLVM build, size gate & code signing
├── generate-icon.swift  # Zero-dependency pure-vector sRGB AppIcon.icns generator (64 KB)
├── install.sh      # One-command install & launch to /Applications/MSnip.app
└── setup-cert.sh   # Local persistent signing certificate helper (keeps TCC permissions across rebuilds)
```

---

<div align="center">

### Star History

<a href="https://www.star-history.com/#xy-tuoren/MSnip&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=xy-tuoren/MSnip&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=xy-tuoren/MSnip&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=xy-tuoren/MSnip&type=Date" />
 </picture>
</a>

</div>

---

## License

[MIT License](LICENSE)
