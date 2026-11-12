# MSnip 开发指南 (AGENTS.md)

## 1. 项目概览
- **名称**：`MSnip`（麦截）
- **定位**：轻量原生 macOS 截图、圈记与贴图工具（Swift + AppKit + CoreGraphics，零外部依赖）。
- **兼容性目标**：`macOS 11.0+`，支持 `arm64` + `x86_64` Universal Binary。

## 2. 架构与目录规范
- `Sources/MSnipCore/`：纯数据与图形渲染核心（不依赖窗口与全局状态，100% 可单测）：
  - `Geometry.swift`：几何计算、八向手柄、点线距离与命中算法、`Shift` 约束。
  - `Annotation.swift`：7 种标注模型（矩形、椭圆、箭头、直线、画笔、马赛克、文字）与样式定义。
  - `Document.swift`：基于 Swift 值类型 CoW 的 100 步快照撤销/重做文档栈。
  - `Renderer.swift`：基于 `CGContext` 的 Retina 物理像素渲染器与导出烘焙器。
- `Sources/MSnip/`：macOS AppKit 平台接入层：
  - `App/`：菜单栏 `NSStatusItem`、应用生命周期与菜单交互。
  - `Config/`：本地 JSON 配置持久化与开机自启兼容封装。
  - `System/`：Carbon 全局热键、剪贴板读写与 PNG 保存面板。
  - `Capture/`：`ScreenCaptureKit` (macOS 14+) 与 `CGWindowListCreateImage` (macOS 11–13) 自适应抓屏。
  - `Overlay/`：全屏冻结覆盖层窗口、框选/标注鼠标键盘交互、悬浮工具栏。
  - `Pin/`：置顶无焦点干扰贴图窗口池（移动、缩放、透明度、右键菜单）。
- `Sources/MSnipTests/`：零外部测试框架依赖的自动化单测套件（兼容仅安装 CommandLineTools 的环境）。
- `scripts/bundle.sh`：一键构建 Release 通用二进制、生成矢量应用图标 `.icns` 并封装签名 `dist/MSnip.app`。

## 3. 代码铁律
1. **单文件 ≤ 300 行**：任何 `.swift` 源文件不得超过 300 行，超出时按职责拆分子文件。
2. **零第三方 Package 依赖**：`Package.swift` 的 `dependencies` 保持为空，仅链接 macOS 系统内置框架。
3. **坐标系明确区分**：
   - 视图与鼠标交互使用窗口逻辑点（`CGPoint` / `CGRect`，在 `isFlipped = true` 的覆盖层视图中统一为**左上角原点**）；
   - 最终导出与马赛克采样按屏幕 `backingScaleFactor` 换算为物理像素，严禁 Retina 模糊失真。
4. **内存零驻留**：截图会话结束后必须释放所有全屏 `CGImage` 与覆盖层窗口引用。

## 4. 常用命令
```bash
swift build                        # Debug 编译检查
swift run MSnipTests               # 运行核心几何/撤销栈/渲染像素单测
bash scripts/bundle.sh             # 构建 Release 通用二进制并打包 dist/MSnip.app
open dist/MSnip.app                # 启动应用（菜单栏常驻）
```
