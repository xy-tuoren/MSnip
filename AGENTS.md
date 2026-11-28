# MSnip 开发指南 (AGENTS.md)

## 1. 项目概览
- **名称**：`MSnip`（麦截）
- **定位**：轻量纯原生 macOS 截图、圈记、贴图、滚动长截图、GIF/MP4 录屏、离线 OCR / LaTeX 识别与多引擎原位/流式翻译工具（零第三方依赖）。
- **兼容性目标**：`macOS 12.0+`（Monterey 及以上），支持 `arm64` + `x86_64` Universal Binary。

## 2. 架构与目录规范
- `Sources/MSnipCore/`：数据模型、核心几何、像素渲染与媒体算法库（不依赖窗口与全局状态，100% 可单测）：
  - `GeometryAndSampling.swift` / `VisualDetector.swift`：几何计算、八向控制柄、像素卡尺、安全采样器与四边闭合视觉边缘探测。
  - `Annotation.swift` / `Document.swift`：12 种工具模型、控制柄、分段橡皮擦与 100 步 CoW 快照撤销/重做栈。
  - `AnnotationRenderer.swift` / `BackdropBeautifier.swift` / `ImageCollageStitcher.swift`：`CGContext` + `Accelerate/vImage` SIMD 高清渲染、衬底美化、多图拼接与合并 PDF。
  - `ScrollFrameDigest.swift` / `ScrollStitcher.swift`：抗侧边栏/Sticky 栏的滚动长图拼接与失步自愈状态机。
  - `MediaClipEncoder.swift` / `RecordingOverlayCompositor.swift`：LZ4 磁盘流式暂存 GIF 与硬件 H.264 MP4 编码器及点击波纹/按键 HUD 合成。
  - `OCRImagePreprocessor.swift` / `OCRTextFormatter.swift` / `OCRLatexModels.swift`：OCR 图像预处理、排版/表格重组与多引擎 OCR/LaTeX 模型配置。
  - `TranslationModels.swift` / `TranslationConfigStore.swift` / `LLMProtocolHelpers.swift`：多协议翻译配置、`0600` 本地隔离与可选系统钥匙串（`Security`）加密凭据仓。
  - `ClipboardImagePromise.swift` / `CaptureHistoryRing.swift` / `ColorSampling.swift` / `ShortcutModels.swift`：延迟剪贴板提供器、异步微缩略图环形历史与取色/快捷键模型。
  - `DiagnosticLog.swift`：`MSnipLog` 本地诊断日志（系统统一日志 + `~/Library/Logs/MSnip` 双文件滚动、写盘前统一脱敏）。
  - `Localization.swift`：`L()` 界面文案本地化（中文原文作键、只认 `%@` 占位符的防崩溃格式化）与界面语言偏好 `MSnipInterfaceLanguage`。
- `Sources/MSnip/`：macOS AppKit 平台接入层：
  - `App/`：菜单栏 `NSStatusItem`、应用主控制器生命周期、快存与各子会话路由。
  - `Config/`：本地 JSON 偏好配置、导出导入/诊断报告与开机自启封装（`SMAppService` / `LaunchAgents`）。
  - `Capture/`：`ScreenCaptureKit` 缓存过滤器抓屏、独立窗口透明阴影截图、`SCStream` 局部流采样与三层区域探测器。
  - `Overlay/`：全屏冻结覆盖层窗口、自动吸附平滑过渡、局部脏矩形重绘、双层悬浮工具栏、长截图会话、原位识字与原位翻译。
  - `Pin/`：置顶无焦点干扰贴图窗口池（Live Text 划词、鼠标穿透、`⌘+拖拽` 直投 PNG、原位二次标注）。
  - `Recording/`：镂空穿透选区录屏会话、倒计时圆环、录制控制栏与裁剪器。
  - `Collage/`：多图拼接与合并 PDF 工作室、内嵌二次标注、色盘与高清大图灯箱。
  - `Shelf/`：顶部高密度暂存架（最近截图、录屏、拖拽文件与文本便签）。
  - `OCR/`：双栏 OCR 识字对照窗、多引擎云 OCR 与 LaTeX 公式识别服务及 `WKWebView` KaTeX 预览。
  - `Translation/`：Apple 原生离线翻译桥接、LLM SSE 流式与主流云翻译客户端、4 标签极客设置中心。
  - `System/`：Carbon/CGEventTap 全局热键、剪贴板/保存面板、双管线 Vision 提取器、全局外观协调、权限引导、Toast HUD、悬浮速览卡与诊断日志接入（`DiagnosticLogging`）。
- `Sources/MSnipTests/`：零外部测试框架依赖的自动化单测套件（兼容仅安装 CommandLineTools 的环境）。
- `Resources/<语言>.lproj/`：`Localizable.strings`（英文译文表，键为源码中的中文原文）与 `InfoPlist.strings`（权限说明）；`bundle.sh` 去掉整行注释后以 UTF-8 文本拷入 App（比二进制 plist 小约 20%），因此注释必须写在单行 `/* … */` 内。
- `scripts/`：`bundle.sh`（单文件行数守门、本机单架构/发版 `--universal` 双架构构建、纯矢量图标 `.icns` 生成与签名）、`install.sh`、`setup-cert.sh`、`update-cask.sh`（发版后按线上 Release 包回写 Cask 的版本号与 SHA256）。

## 3. 代码铁律
1. **按模块内聚组织（硬护栏 ≤ 800 行）**：同一类或同一完整职责模块优先放在同一文件（推荐 200–600 行），避免为机械凑行数将单模块过度切碎；同时任何 `.swift` 源文件不得超过 800 行，超出时按清晰边界拆分。
2. **零第三方 Package 依赖**：`Package.swift` 的 `dependencies` 保持为空，仅链接 macOS 系统内置框架。
3. **坐标系明确区分**：
   - 视图与鼠标交互使用窗口逻辑点（`CGPoint` / `CGRect`，在 `isFlipped = true` 的覆盖层视图中统一为**左上角原点**）；
   - 最终导出与马赛克/毛玻璃采样按屏幕 `backingScaleFactor` 换算为物理像素，严禁 Retina 模糊失真。
4. **内存零驻留**：截图/录屏/预览会话结束后必须释放所有全屏 `CGImage`、临时暂存文件、渲染切片缓存与子进程窗口引用。
5. **日志只记事件不记内容**：失败路径用 `MSnipLog` 记录事件、计数、状态码与 `error:`；绝不传入截图内容、识别/翻译/剪贴板文本、API Key、接口地址或完整路径，也不在鼠标移动、逐帧编码等高频路径打日志。
6. **界面文案走 `L()`**：用户可见文案写成 `L("中文原文")`，带参数的写成 `L("已复制 %@ 项", count)`（只用 `%@`，不要插值进键），并在 `Resources/en.lproj/Localizable.strings` 补英文；`swift run MSnipTests` 会拦下缺译、多余键、占位符不一致与仍含中文的译文。日志、发给模型的提示词、用于匹配或持久化的字符串不包 `L()`。固定宽度的按钮与分段控件用 `widthFitting(atLeast:)` / `fittingWidth` 给较长译文留位（`GeekTheme.drawText` 放不下时会先缩字到 82% 再截断，`GeekButton` 截断时自动补完整提示，分段控件放不下自动按文字宽度分配，这些只是兜底）。改完界面必须运行 `swift run MSnip --debug-render-settings <目录> --lang en`（中文去掉 `--lang en` 再跑一次）：它会离屏渲染各窗口并输出 `truncation-report-*.txt`，有任何截断时以退出码 2 结束，报告清零才算完成；新增窗口或弹窗时把它加进渲染清单。显示服务名用 `TranslationProviderProfile.displayName`（内置默认名随界面语言翻译），不要直接显示 `name`。

## 4. 常用命令
```bash
swift build                             # Debug 编译检查
swift run MSnipTests                    # 运行全部核心几何/撤销栈/渲染/长图/录屏/翻译单测
bash scripts/bundle.sh                  # 本机单架构极致瘦身打包（< 3 MB）
bash scripts/bundle.sh --universal      # 构建 Release 双架构通用二进制（发版用）
bash scripts/install.sh                 # 停止旧实例并安装启动至 /Applications/MSnip.app
bash scripts/update-cask.sh             # 上传 Release 后，把线上 Universal Zip 的 SHA256 写入 Casks/msnip.rb
swift run MSnip --debug-render-settings /tmp/shots --lang en  # 仅 Debug：离屏渲染设置窗口（含各服务/引擎表单与三个弹窗）、权限引导、各工具栏、速览卡、暂存架与拼图窗口，并做截断审计（只读，不碰用户配置；有截断退出码 2）
```
