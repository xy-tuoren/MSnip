<div align="center">

# MSnip

### A Sub-3 MB Pure-Native macOS Screenshot, Annotation, Pin, Recorder, OCR & Translation Utility

**Only `2.7 MB` native (`1.3 MB` zipped), zero third-party dependencies, `0%` idle CPU, and zero idle bitmap retention — packing 12 annotation tools, offline privacy auto-redaction, noise-immune smart region snapping, desktop pins, a top drop shelf, collage/PDF merge, vertical & horizontal scrolling capture, high-FPS hardware recording with lossless filmstrip trimming, multi-engine OCR/LaTeX, and in-place translation into one ultra-light native Swift app. Source-available and free for personal & noncommercial use.**

<p align="center">
  <a href="https://github.com/xy-tuoren/MSnip/releases"><img alt="Release" src="https://img.shields.io/github/v/release/xy-tuoren/MSnip?style=flat-square&label=release&color=0C6EF3"></a>
  <a href="https://github.com/xy-tuoren/MSnip/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/xy-tuoren/MSnip/ci.yml?style=flat-square&label=CI"></a>
  <a href="https://github.com/xy-tuoren/MSnip/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/xy-tuoren/MSnip?style=flat-square&color=E3B341"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-12.0%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="Native Size" src="https://img.shields.io/badge/Native_App-2.7_MB-6366F1?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Pure_Native-Swift_5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Zero Dependencies" src="https://img.shields.io/badge/3rd--Party_Deps-0-10B981?style=flat-square">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-PolyForm_Noncommercial_1.0-D97706?style=flat-square"></a>
  <a href="https://linux.do/"><img alt="LINUX DO" src="https://img.shields.io/badge/LINUX_DO-Community-1677FF?style=flat-square"></a>
</p>

[简体中文](README.md) · **English**

**[Why MSnip](#-why-msnip-five-core-advantages) · [Deep Comparison](#-in-depth-comparison) · [30s Quick Start](#-30-second-quick-start) · [Performance Budget](#-performance--footprint-budget-measured) · [Screenshots](#-screenshots) · [Installation](#-installation) · [FAQ](#-faq) · [License](#-license-noncommercial-source-available)**

</div>

<br/>

![MSnip Capture Overlay: frozen screen, 12 annotation tools, offline privacy redaction, and pixel magnifier](docs/msnip-hero.jpg)

*Pressing `⌥A`: instant frozen canvas, noise-immune smart window/card/control snapping, 120Hz VSync floating toolbar & tooltips, 1-click offline redaction of API keys / emails / phone numbers, live corner radius & luminous glow pills, and a zero-copy 15×7 GPU pixel loupe.*

---

## Why MSnip? Five Core Advantages

Most macOS power users end up running 3–4 menu bar utilities just to cover everyday visual workflows (screenshots + desktop pins + scrolling/recording + OCR/translation), paying yearly subscriptions for closed-source suites, or carrying 50–120+ MB Electron/Qt wrappers bundled with `ffmpeg`.

**MSnip v1.0.0 refuses to trade capability for lightness**: zero external packages, written strictly in native Swift against Apple frameworks, fitting a complete visual productivity suite into **`2.7 MB`**.

### 1. Ultra-Light All-in-One (`2.7 MB` vs `50–120+ MB`)
- **Just `2.7 MB` native (`1.3 MB` zipped)** — 4× to 40× smaller than popular alternatives while covering screenshots, 12 annotation tools, offline auto-redact, desktop pins, top drop shelf, collage/PDF merge, vertical & horizontal scrolling capture, high-FPS recording + lossless trimming, 6 OCR engines, LaTeX formulas, and in-place translation.
- **`0.0%` idle CPU & immediate memory reclamation**: strictly event-driven with zero background polling; closing any session immediately releases full-screen `CGImage` buffers, tile caches, temporary clips, and WebKit helper processes.

### 2. Purpose-Built for Developers & AI Coding Workflows
- **Context-Aware Terminal & AI IDE Paste**: Copy a screenshot and press `⌘V` in Ghostty / iTerm2 / Terminal or embedded IDE terminals (VS Code / Cursor / Zed / JetBrains / Claude Code / Codex) to **automatically paste a space-free temporary `.png` path** — while still pasting raw images into WeChat / Slack / docs and files into Finder.
- **1-Click Offline Privacy Auto-Redact**: On-device Vision locates and masks **API keys / JWTs, emails, phone numbers, 18-digit IDs, non-loopback IPv4 addresses, and bank cards** in one `⌘Z`-undoable step before you share bug reports or docs.
- **Instant Markdown / TSV Tables & LaTeX Formulas**: Extract multi-column tables directly to Markdown or spreadsheet TSV; recognize equations with Vision LLMs / SimpleTex / Mathpix plus instant offline WebKit MathML and KaTeX preview.

### 3. 120Hz Native Feel & Noise-Immune Smart Region Snapping
- **Accurate, Calm Region Detection**: Combines window snapshots + semantic Accessibility role filtering + **4-side closed pixel edge & polarity coherence verification** + **velocity-aware sweep damping**. Invisible browser/Electron `<div>` wrappers and terminal text noise are filtered out; sweeping fast stays calmly on whole windows, decelerating locks cleanly onto real visible cards or controls, and scroll / `[` `]` steps cleanly through tiers.
- **End-to-End 120Hz VSync Responsiveness**: Toolbar hover highlights, high-level floating tooltips, pixel magnifier, and snap borders are driven directly by display VSync, eliminating sluggish non-activating panel tracking and occluded native tooltips; the status bar menu uses native zero-latency macOS tracking.

### 4. High-FPS Hardware Recording + Filmstrip Trimmer & Bidirectional Scrolling Capture
- **High-FPS MP4 / GIF Recording**: MP4 streams straight into VideoToolbox hardware H.264 (Standard / HD / Original Retina 1:1, 30 / 60 / native high-refresh FPS, macOS 13+ system audio, click ripples, keystroke HUD, and **live pen/laser annotation while recording**), followed by a **10-tile filmstrip lossless MP4 trimmer** with smooth live frame scrubbing; GIF spools frames to disk with LZ4 to avoid RAM spikes.
- **Vertical & Horizontal Scrolling Capture**: Rejects sticky headers, footers, and static sidebars, supports **`⌘Z` undo last segment**, and self-recovers from scroll desyncs.

### 5. Local-First & Fully Inspectable Source
- Screenshot tools hold macOS's highest-trust *Screen Recording* permission. MSnip's **entire Swift codebase is public and auditable** — no accounts, no telemetry, no hidden uploads. Capture, annotation, auto-redact, OCR, QR scanning, scrolling stitch, recording, and macOS 15+ Apple native translation run **100% on-device**. Optional cloud API keys stay isolated in `0600` local files or macOS Keychain.

---

## In-Depth Comparison

> Summarized from publicly documented capabilities across popular macOS screenshot utilities.

| Capability | Built-in macOS | Shottr | Snipaste | CleanShot X | PixPin | **MSnip v1.0** |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Source & Personal Use** | Built-in | Closed · Paid Pro | Closed · Paid Pro | Closed · $29 + Renewals | Closed · Subscription | **Source-Available · Free for Personal/Noncommercial** |
| **Stack & Dependencies** | Built-in | Native Swift | Qt / C++ | Native Swift + Closed SDKs | Qt / C++ + External Engines | **100% Pure Native Swift · 0 External Deps** |
| **App Footprint** | Built-in | ~10 MB | ~55 MB | ~50+ MB | ~120+ MB | **Native `2.7 MB` (Universal `6.0 MB`)** |
| **Smart Region Snapping** | Window only | Basic edges | Window / UI | Window only | Window / UI | **Semantic AX + 4-Edge Pixel Coherence + Velocity Damping** |
| **Annotations & Privacy** | Basic | Rich markup | Rich markup | Rich + manual redact | Rich markup | **12 Tools + Spotlight + Offline Auto-Redact** |
| **Desktop Pinning** | None | Single-image pin | Strong pin | Basic pin | Strong pin | **Luminous Glow + 8-Way Resize + Live Text + Ghost Mode + File Drag** |
| **Top Shelf & Collage/PDF** | None | None | None | Simple history | None | **98pt Top Shelf + Multi-Image Collage (w/ Editor) + PDF Merge** |
| **Scrolling Capture** | None | Vertical only | None | Vertical only | Vertical & Horizontal | **Vertical & Horizontal + Undo Step + Sticky/Sidebar Rejection** |
| **Recording & Trimming** | Basic | None | None | Paid | GIF / Video | **High-FPS H.264 + System Audio + Live Draw + Filmstrip Lossless Trim** |
| **OCR / Tables / Translate / LaTeX** | Preview only | Offline OCR | None | Offline OCR | OCR + Pin Translate | **6 OCR Engines + Markdown Tables + In-Place Translate + LaTeX** |
| **Terminal / AI IDE Paste** | None | None | None | None | None | **Context-Aware (Path in Terminals / Raw Image in Chat)** |
| **Idle Energy & Memory** | System | Light | Medium | Heavy | Heavy | **`0%` Idle CPU · Immediate Bitmap Release** |

---

## 30-Second Quick Start

Once launched, MSnip lives quietly in the menu bar — no Dock icon, no background polling:

1. **Smart Capture + Terminal / AI IDE Path Paste**: Press **`⌥A`** to freeze the screen → move over any real card or window (scroll or press `[` `]` to step tiers) → click or drag → double-click to copy. Press `⌘V` in **Terminal / Ghostty / Cursor / Claude Code / Codex** to paste a space-free `.png` path automatically, or `⌘V` in chat/docs for the raw image.
2. **1-Click Offline Privacy Auto-Redact**: Click the privacy redact icon in the toolbar to automatically mask API keys, JWTs, phone numbers, emails, ID numbers, and IPv4 addresses on-device (`⌘Z` undoes the entire batch).
3. **Desktop Pins & Top Drop Shelf**: Press **`P`** to pin any capture on screen (Live Text, click-through `P`, `⌘+Drag` out as a `.png`); push your pointer against the top screen edge to reveal the **98pt Top Shelf** and `⌘+Click` multiple items into the Collage / PDF Studio.
4. **High-FPS Recording + Filmstrip Lossless Trim**: Press **`⌥R`** to record with optional live pen/laser markup; finish an MP4 via the scissors icon to scrub live frames on a 10-tile filmstrip and trim losslessly in milliseconds.

---

## Performance & Footprint Budget (Measured)

| Metric | Measured Result | Engineering Notes |
| :--- | :--- | :--- |
| **Native App Bundle (`arm64`)** | **`2.7 MB`** (`1.3 MB` zipped) | `2,728 KB` via `scripts/bundle.sh` (hard gate `≤ 3.0 MiB`) |
| **Universal Bundle (`arm64` + `x86_64`)** | **`6.0 MB`** (`2.9 MB` zipped) | Dual-arch Universal Binary for GitHub Releases & Homebrew |
| **App Icon (`AppIcon.icns`)** | **`68 KB`** | Pure CoreGraphics vector + adaptive 5-filter `zlib-9` + 8 `sRGB` slices |
| **Idle CPU Usage** | **`0.0%`** | Strictly event-driven — zero background polling timers |
| **Post-Session Memory Retention** | **Immediate Release** | Full-screen `CGImage`, tile caches, temp clips & WebKit processes freed on close |
| **Overlay & Chrome Rendering** | **120Hz Native Smooth** | Hardware VSync + static GPU dim layers + dirty-rect redraws + zero-copy loupe |
| **Hardware Recording Pipeline** | **60 / 120 fps** | Zero-copy VideoToolbox H.264 MP4; LZ4 disk-spooled GIF prevents RAM spikes |
| **Retina & Color Accuracy** | **Native Display P3** | Decoupled logical/physical coordinates with end-to-end display ICC preservation |

**How does MSnip stay under `3 MB` without sacrificing capability or stability?**
1. **Zero Third-Party Dependencies**: Empty `dependencies` in `Package.swift` — built directly on macOS `AppKit`, `ScreenCaptureKit`, `Accelerate/vImage`, `Vision`, `VideoToolbox`, `AVFoundation`, and `Translation`.
2. **Single-Unit Whole-Module LLVM Optimization**: Release builds combine `-Osize` + `-cross-module-optimization` + `-enable-single-module-llvm-emission` + `-exported_symbol _main` while **preserving full Swift reflection metadata** for 100% safe SwiftUI / `Translation` / `VisionKit` interop.
3. **Pure-Vector High-Compression Icon**: [generate-icon.swift](scripts/generate-icon.swift) renders every resolution crisply in CoreGraphics and emits a `68 KB` tagged `sRGB` `.icns`.

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

### 1. Precision Capture, Noise-Immune Smart Snapping & Custom Delay
- **Smart Multi-Level Snapping**: Detects Dock items, menu bar items, windows, compact UI controls, and 4-edge verified visual cards while filtering invisible browser/Electron wrappers and terminal text noise; sweeps smoothly at window level and locks on deceleration, with scroll / `[` `]` stepping between *Control ↔ Region ↔ Window ↔ Full Screen* (`W` snaps directly to the underlying window).
- **Custom Delayed Capture (`⌥W`, `1–60s`)**: Floating countdown ring (click to shoot immediately; `Esc` cancels) with modal-menu focus guards so open dropdown menus capture cleanly.
- **Instant Fullscreen Capture (`⌥S`)**: Captures the display under your cursor with configurable default action (**Copy / Save / Copy & Save**).
- **Isolated Clean Window (`F` / `⇧↩`)**: Strips desktop clutter and exports a single window with native macOS transparent shadow.
- **Corner Radius & Luminous Glow (`B` / `G`)**: Drag or scroll the top-right side pills to tune `0%–100%` rounded corners and soft outer glow live.
- **Multi-Format Export & Non-Intrusive Feedback**: Auto-probes `PNG / JPG / HEIC / AVIF / BMP / TIFF`, Retina `1×` downscaling, custom filename templates (`MSnip-{date}-{time}-{w}x{h}`), silent clipboard copy, and a translucent Quick-Access card on file save & recording completion.

### 2. 12 Annotation Tools, Spotlight & 1-Click Offline Auto-Redact
- **Full Toolkit**: Rectangle, Ellipse, Arrow, Line, Bézier Pen, Highlighter, auto-incrementing Step badges `①②③`, Mosaic, SIMD Gaussian Blur, **Spotlight highlight**, Capsule Text, and segmented Eraser.
- **1-Click Offline Auto-Redact**: Detects and masks API keys/JWTs, emails, phone numbers, 18-digit IDs, non-loopback IPv4 addresses, and bank cards locally — undoable in one `⌘Z`.
- **Post-Edit Handles, Cloning & 100-Step Undo**: Select any shape to refine corners/endpoints; **`⌘C` / `⌘V`** copy-paste and **`⌘D`** duplicate in place (auto-incrementing step numbers), backed by a 100-step Copy-on-Write Undo/Redo stack.

### 3. Desktop Pins, Top Drop Shelf & Collage / PDF Studio
- **Compact Top Drop Shelf (MSnip Shelf)**: Supports **Hover to Expand** (strict top-edge `≤ 1.5pt` `0.55s` dwell anti-misfire, `80ms` drag-to-top reveal), **Hotkey Toggle**, and **Always Shown**; `98pt` height holding up to 9 cards with click-to-copy, `✎` annotate, `⌘ + Click` ordered multi-select for collage, and drag-out sharing. Menu bar icon opens the action menu on **left- or right-click**, with **`⌥ + Left-Click`** toggling the Top Shelf.
- **Desktop Pins**: Soft white/blue luminous outer glow synced `0%–100%` across Settings, selection overlay, and `⌥ + Scroll`; 8-way hover resizing, on-pin Live Text selection, `⌘ + Drag` out as `.png`, Click-Through Ghost Mode (`P`), `8pt` magnetic snapping, and an unobstructed floating action bar.
- **Multi-Image Collage & PDF Merge Studio**: Drag-in, reorder, **embedded in-window annotation editing**, **Stitch Image** mode (Horizontal / Vertical / 2–4 Col Grid, aspect presets, gap/padding/radius/shadow/2D color picker + eyedropper/gradients/badges/watermark), and lossless **Merge Multi-Page PDF** mode.

### 4. Vertical & Horizontal Scrolling Capture (`⌥E` / `L`) & High-FPS Recording / Trimming (`⌥R` / `V`)
- **Scrolling Capture**: Lossless live sampling that rejects sticky headers, footers, and static sidebars — supporting **Vertical Down** and **Horizontal Right** stitching, **`⌘Z` undo last step**, and desync auto-recovery.
- **High-FPS GIF / MP4 Recording & Filmstrip Trimmer**: MP4 offers **Standard / HD / Original (Retina 1:1)** at **30 / 60 / Native High Refresh Rate**, **macOS 13+ native system audio capture**, click ripples, keystroke HUD, **live pen/laser annotation during recording**, and a built-in **10-tile filmstrip lossless MP4 trimmer** (`Space` play/pause, smooth live frame scrubbing, `Esc`/`⌘W` close, instant `Passthrough` export); GIF offers **Compact / Standard / HD**.

### 5. Multi-Engine Translation, OCR (Offline + Cloud + Vision LLM) & LaTeX (`⌥D` / `⌥F`)
- **Paragraph In-Place & Streaming Translation**: Supports **macOS 15+ Apple Native Offline Translation**, plus **OpenAI Chat / OpenAI Responses (`/v1/responses`) / Anthropic Messages / Gemini Native** (with reasoning-block filtering) alongside DeepSeek, Zhipu, Qwen, Doubao, Kimi, Tencent, Baidu, Youdao, DeepL, Ollama, and custom relays with failover.
- **3 OCR Modes & 6 OCR Engines**: **In-Place Live Text / Dual-Pane / Silent Copy**; alongside **Apple Offline Vision**, switch freely to **Vision LLMs / Baidu / Tencent / Youdao / Custom HTTP** (compatible with Umi-OCR / PaddleOCR / RapidOCR), export tables as **Markdown / TSV**, and detect QR/barcodes silently.
- **LaTeX Formula Recognition**: Vision LLMs, SimpleTex, Mathpix, and offline fallback with instant offline native WebKit MathML rendering and online KaTeX progressive enhancement.

### 6. CLI & `msnip://` URL Scheme Automation
- Integrates seamlessly with Raycast, Alfred, Apple Shortcuts, and shell scripts via `open msnip://capture`, `msnip://translate`, `msnip://ocr`, `msnip://silent-ocr`, `msnip://shelf`, `msnip://long`, `msnip://record`, `msnip://pin`, `msnip://settings`, or `MSnip --enter=ocr|shelf|long|video|pin`. For security, an externally triggered `fullscreen` never captures silently; it opens the capture overlay for you to confirm, so other processes cannot borrow MSnip's Screen Recording permission.

---

## Installation

### Requirements
- **macOS 12.0 (Monterey) or later** (Apple Silicon `arm64` & Intel `x86_64`)
  - Live Text & MP4 native system audio capture: macOS 13.0+
  - `ScreenCaptureKit` fast silent capture: macOS 14.0+ (automatic fallback on macOS 12–13)
  - Apple native offline translation: macOS 15.0+
- **Permissions**: **Screen Recording** (Required for capture/recording); **Accessibility** (Optional for UI-control snapping, IDE terminal detection, and priority hotkey takeover).

### Option 1: Build & Install Native `2.7 MB` App from Source (Recommended)

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/xy-tuoren/MSnip.git
cd MSnip
bash scripts/install.sh --rebuild
```

> [!TIP]
> Run `bash scripts/setup-cert.sh` once to generate a persistent local signing certificate in your Keychain so future rebuilds preserve macOS Screen Recording and Accessibility permissions automatically.

### Option 2: Direct Download from GitHub Releases (Universal / Native `arm64`)

Download from **[GitHub Releases (Latest)](https://github.com/xy-tuoren/MSnip/releases/latest)**:
- **Universal Binary (Apple Silicon + Intel)**: `MSnip-v*-macOS.zip` (`~2.9 MB`)
- **Apple Silicon Native (`arm64`)**: `MSnip-v*-macOS-arm64.zip` (`~1.3 MB`)

Unzip and move `MSnip.app` to `/Applications`. If macOS Gatekeeper flags the unsigned download on first launch, run:

```bash
xattr -cr /Applications/MSnip.app
```

### Option 3: Homebrew Cask

```bash
brew tap xy-tuoren/msnip https://github.com/xy-tuoren/MSnip
brew install --cask msnip
```

> The Cask postflight clears quarantine attributes automatically.

---

## FAQ

<details>
<summary><strong>macOS says "MSnip is damaged and can't be opened" or "unverified developer"?</strong></summary>

MSnip is an independent free utility signed ad-hoc rather than notarized with a paid Apple Developer subscription, so macOS tags browser downloads with `com.apple.quarantine`. Run `xattr -cr /Applications/MSnip.app` once, or install via Homebrew Cask / `bash scripts/install.sh --rebuild`.

</details>

<details>
<summary><strong>Do I need to re-grant Screen Recording / Accessibility permissions after upgrading?</strong></summary>

Normal daily usage and reboots keep permissions intact. If you rebuild frequently from source, run `bash scripts/setup-cert.sh` once to create a persistent local signing certificate in your Keychain — future rebuilds keep the exact same code signature and preserve TCC permissions automatically.

</details>

<details>
<summary><strong>Does MSnip phone home, collect telemetry, or upload screenshots?</strong></summary>

**Never.** MSnip is 100% source-available with zero third-party SDKs, zero accounts, and zero telemetry. Capture, annotations, privacy auto-redaction, Apple Vision OCR, QR scanning, scrolling stitch, recording/trimming, and macOS 15+ Apple native translation run completely offline. Network calls occur only when you explicitly configure and invoke a third-party cloud translation / OCR / LaTeX endpoint, with one exception: the LaTeX result window's preview downloads a pinned, SRI-verified copy of KaTeX from the jsDelivr CDN (static files only, no formula content is sent; offline it falls back to built-in MathML).

</details>

<details>
<summary><strong>Why PolyForm Noncommercial 1.0.0 instead of MIT?</strong></summary>

To keep 100% of the source code public, auditable, and free for personal/noncommercial use and self-compilation while prohibiting unauthorized commercial resale, closed-source repackaging, or bundling into paid products.

</details>

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
| Move / Scroll / `[` `]` | Smart snap between Control, Region, Window & Full Screen |
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

MSnip enforces cohesive modularity and zero third-party dependencies: **111 `.swift` files** gated at `≤ 800` lines in CI, pure core algorithms decoupled from AppKit UI, and a zero-dependency unit test suite (**420 assertions**).

```bash
swift build                             # Debug compile check (0 Swift warnings)
swift run MSnipTests                    # Run all 420 core unit test assertions
bash scripts/bundle.sh                  # Native single-arch build (2.7 MB)
bash scripts/bundle.sh --universal      # Dual-arch Universal Binary (6.0 MB, CI/Releases)
```

```text
Sources/
├── MSnipCore/      # Pure algorithms & models (geometry, 4-edge visual detector, 12 annotations, vImage SIMD renderer, scroll stitcher, GIF/MP4 encoder, OCR/PII detector, hotkeys & credential vault)
├── MSnip/          # macOS AppKit layer (menu bar, ScreenCaptureKit capture, 120Hz frozen overlay, pin pool, shelf, collage, recorder & trimmer, OCR/LaTeX, translation & settings UI)
└── MSnipTests/     # Zero-dependency automated test suite (420 assertions)
scripts/
├── bundle.sh       # <=800-line gate, Release -Osize single-unit LLVM build, size gate & code signing
├── generate-icon.swift  # Zero-dependency pure-vector sRGB AppIcon.icns generator (68 KB)
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

## Privacy

MSnip is strictly local-first: zero accounts, zero analytics, zero ads, and zero background network requests. Outbound requests happen only when you explicitly configure and trigger a cloud OCR, translation, or LaTeX provider, and when the LaTeX result window loads a pinned, SRI-verified copy of KaTeX from the jsDelivr CDN for typesetting (no formula content is sent).

## Acknowledgments

Thanks to the **[LINUX DO](https://linux.do/)** community for feedback, ideas, and support.

[![LINUX DO](https://img.shields.io/badge/LINUX%20DO-Community-1677FF?style=flat-square)](https://linux.do/)

## License (Noncommercial Source-Available)

MSnip is licensed under the **[PolyForm Noncommercial License 1.0.0](LICENSE)** (SPDX: `PolyForm-Noncommercial-1.0.0`):

- **Permitted**: Free personal, study, research, and noncommercial use, source code inspection, self-compilation, modification, and noncommercial sharing (must preserve copyright notices and license terms).
- **Prohibited**: **Any commercial use is prohibited without explicit written permission from the author** — including selling, commercial redistribution, rebranding/wrapping into paid apps, or integrating into commercial services.
- **Commercial Licensing**: For commercial, enterprise, or redistribution licensing inquiries, please contact the author via [GitHub Issues](https://github.com/xy-tuoren/MSnip/issues).
