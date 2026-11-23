# MSnip 开发指南 (AGENTS.md)

## 1. 项目概览
- **名称**：`MSnip`（麦截）
- **定位**：轻量纯原生 macOS 截图、圈记、贴图、滚动长截图、GIF/MP4 录屏、离线 OCR / LaTeX 识别与多引擎原位/流式翻译工具（零第三方依赖）。
- **兼容性目标**：`macOS 12.0+`（Monterey 及以上），支持 `arm64` + `x86_64` Universal Binary。

## 2. 架构与目录规范
- `Sources/MSnipCore/`：数据模型、核心几何、像素渲染与媒体算法库（不依赖窗口与全局状态，100% 可单测）：
  - `Geometry.swift` / `PixelCaliper.swift` / `VisualDetector.swift`：几何计算、八向控制柄、像素卡尺与四边闭合视觉边缘探测。
  - `Annotation.swift` / `AnnotationEraser.swift` / `Document.swift`：11 种工具模型（矩形、椭圆、箭头、直线、画笔、智能荧光笔、步骤序号、马赛克、高斯毛玻璃、文字/胶囊字、分段橡皮擦）与 100 步 CoW 快照撤销/重做栈。
  - `Renderer.swift` / `EffectsRenderer.swift` / `RedactionRenderer.swift` / `BackdropBeautifier.swift`：`CGContext` + `Accelerate/vImage` SIMD 高清渲染与渐变衬底烘焙。
  - `ScrollFrameDigest.swift` / `ScrollStitcher.swift`：抗侧边栏/Sticky 栏的滚动长图拼接与失步自愈状态机。
  - `MediaClipEncoder.swift` / `GIFDiskSpooler.swift` / `RecordingOverlayCompositor.swift`：LZ4 磁盘流式暂存 GIF 与硬件 H.264 MP4 编码器及点击波纹/按键 HUD 合成。
  - `OCRImagePreprocessor.swift` / `OCRTextFormatter.swift` / `LatexFormulaModels.swift`：OCR 图像超分预处理、排版重组与 LaTeX 后处理。
  - `TranslationModels.swift` / `TranslationConfigStore.swift` / `CredentialVault.swift`：多协议翻译配置、`0600` 本地隔离与可选系统钥匙串（`Security`）加密凭据仓。
  - `ClipboardImagePromise.swift` / `CaptureHistoryRing.swift` / `ColorSampling.swift` / `KeyCombo.swift`：延迟剪贴板提供器、异步微缩略图环形历史与取色/快捷键模型。
- `Sources/MSnip/`：macOS AppKit 平台接入层：
  - `App/`：菜单栏 `NSStatusItem`、应用主控制器生命周期、快存与各子会话路由。
  - `Config/`：本地 JSON 偏好配置与开机自启兼容封装（`SMAppService` / `LaunchAgents`）。
  - `Capture/`：`ScreenCaptureKit` 缓存过滤器抓屏、独立窗口透明阴影截图、`SCStream` 局部流采样与三层区域探测器。
  - `Overlay/`：全屏冻结覆盖层窗口、自动吸附平滑过渡、局部脏矩形重绘、双层悬浮工具栏、长截图会话、原位识字与原位翻译。
  - `Pin/`：置顶无焦点干扰贴图窗口池（Live Text 划词、鼠标穿透、`⌘+拖拽` 直投 PNG、原位二次标注）。
  - `Recording/`：镂空穿透选区录屏会话、倒计时圆环与录制控制栏。
  - `OCR/`：双栏 OCR 识字对照窗、多引擎 LaTeX 公式识别服务与 `WKWebView` KaTeX 预览。
  - `Translation/`：Apple 原生离线翻译桥接、LLM SSE 流式与主流云翻译客户端、3 标签极客设置中心。
  - `System/`：Carbon 全局热键、剪贴板/保存面板、双管线 Vision 提取器、权限引导与 Toast HUD。
- `Sources/MSnipTests/`：零外部测试框架依赖的自动化单测套件（兼容仅安装 CommandLineTools 的环境）。
- `scripts/`：`bundle.sh`（单文件行数守门、Release 双架构构建、矢量图标 `.icns` 生成与签名）、`install.sh`、`setup-cert.sh`。

## 3. 代码铁律
1. **单文件 ≤ 300 行**：任何 `.swift` 源文件不得超过 300 行，超出时按职责拆分子文件。
2. **零第三方 Package 依赖**：`Package.swift` 的 `dependencies` 保持为空，仅链接 macOS 系统内置框架。
3. **坐标系明确区分**：
   - 视图与鼠标交互使用窗口逻辑点（`CGPoint` / `CGRect`，在 `isFlipped = true` 的覆盖层视图中统一为**左上角原点**）；
   - 最终导出与马赛克/毛玻璃采样按屏幕 `backingScaleFactor` 换算为物理像素，严禁 Retina 模糊失真。
4. **内存零驻留**：截图/录屏/预览会话结束后必须释放所有全屏 `CGImage`、临时暂存文件、渲染切片缓存与子进程窗口引用。

## 4. 常用命令
```bash
swift build                        # Debug 编译检查
swift run MSnipTests               # 运行全部核心几何/撤销栈/渲染/长图/录屏/翻译单测
bash scripts/bundle.sh             # 构建 Release 通用二进制并打包 dist/MSnip.app
open dist/MSnip.app                # 启动应用（菜单栏常驻）
```
