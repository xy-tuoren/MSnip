#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MSnip"
VERSION="0.3.2"
BUNDLE_ID="top.xy.msnip"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> [1/5] 运行单文件行数守门检查 (≤ 300 行)..."
OVER_LIMIT=0
while IFS= read -r file; do
    lines=$(wc -l < "$file" | tr -d ' ')
    if [ "$lines" -gt 300 ]; then
        echo "  ❌ 超出 300 行限制: $file ($lines 行)"
        OVER_LIMIT=1
    fi
done < <(find Sources -name '*.swift')
if [ "$OVER_LIMIT" -ne 0 ]; then
    exit 1
fi
echo "  ✓ 所有 Swift 源文件均符合 ≤ 300 行约束"

echo "==> [2/5] 构建 Release 二进制..."
rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

swift build -c release --product "$APP_NAME"
ARM_SRC="$(swift build -c release --show-bin-path)/$APP_NAME"
ARM_TMP="$DIST_DIR/${APP_NAME}_arm"
cp "$ARM_SRC" "$ARM_TMP"

FINAL_BIN="$DIST_DIR/${APP_NAME}_bin"
if [ "$(uname -m)" = "arm64" ] && swift build -c release --product "$APP_NAME" --triple x86_64-apple-macosx14.0 >/dev/null 2>&1; then
    X86_SRC="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/$APP_NAME"
    if [ -f "$X86_SRC" ] && [ "$(lipo -archs "$X86_SRC")" != "$(lipo -archs "$ARM_TMP")" ]; then
        lipo -create "$ARM_TMP" "$X86_SRC" -output "$FINAL_BIN"
        echo "  ✓ 已合成双架构 Universal Binary ($(lipo -archs "$FINAL_BIN"))"
    else
        cp "$ARM_TMP" "$FINAL_BIN"
    fi
else
    cp "$ARM_TMP" "$FINAL_BIN"
    echo "  ✓ 已生成当前架构原生优化二进制 ($(lipo -archs "$FINAL_BIN"))"
fi
rm -f "$ARM_TMP"

strip -x "$FINAL_BIN" 2>/dev/null || true
cp "$FINAL_BIN" "$MACOS_DIR/$APP_NAME"
rm -f "$FINAL_BIN"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "==> [3/5] 生成矢量应用图标 AppIcon.icns..."
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
swift - "$ICONSET_DIR" << 'SWIFT_ICON'
import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func renderIcon(px: Int) -> Data? {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let pad = s * 0.09
    let card = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = card.width * 0.225
    let bgPath = CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.08, green: 0.48, blue: 0.98, alpha: 1.0),
        CGColor(srgbRed: 0.05, green: 0.22, blue: 0.58, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    ctx.restoreGState()

    // 绘制白色取景框角标与中心圆点
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.setLineWidth(max(1.5, s * 0.065))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let inset = s * 0.27
    let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let arm = box.width * 0.30

    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: box.minX, y: box.maxY - arm), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX + arm, y: box.maxY)),
        (CGPoint(x: box.maxX - arm, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY - arm)),
        (CGPoint(x: box.maxX, y: box.minY + arm), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX - arm, y: box.minY)),
        (CGPoint(x: box.minX + arm, y: box.minY), CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.minY + arm))
    ]
    for (p1, p2, p3) in corners {
        ctx.beginPath()
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.addLine(to: p3)
        ctx.strokePath()
    }

    let dotR = s * 0.065
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.78, blue: 0.18, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: s * 0.5 - dotR, y: s * 0.5 - dotR, width: dotR * 2, height: dotR * 2))

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let mapping: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, px) in mapping {
    if let data = renderIcon(px: px) {
        try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
SWIFT_ICON

iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "==> [4/5] 写入 Info.plist 并执行本地代码签名..."
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MSnip 需要屏幕录制权限以捕捉并冻结当前屏幕区域供你圈记和贴图。</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> [5/5] 压缩分发包并校验体积红线..."
ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macOS.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo ""
echo "=========================================="
echo "✅ 打包完成！"
echo "  App 路径: $APP_BUNDLE"
echo "  二进制架构: $(file "$MACOS_DIR/$APP_NAME" | sed 's/.*: //')"
echo "  App 总大小: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
echo "  Zip 包大小: $(du -sh "$ZIP_PATH" | awk '{print $1}')"
echo "=========================================="
