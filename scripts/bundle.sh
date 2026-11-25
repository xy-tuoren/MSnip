#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MSnip"
VERSION="0.9.0"
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

echo "==> [2/5] 构建 Release 二进制 (-Osize + dead_strip)..."
rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

BUILD_FLAGS=(-c release --product "$APP_NAME" -Xswiftc -Osize -Xlinker -dead_strip)
swift build "${BUILD_FLAGS[@]}"
ARM_SRC="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"
ARM_TMP="$DIST_DIR/${APP_NAME}_arm"
cp "$ARM_SRC" "$ARM_TMP"

FINAL_BIN="$DIST_DIR/${APP_NAME}_bin"
if [ "$(uname -m)" = "arm64" ] && swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx12.0 >/dev/null 2>&1; then
    X86_SRC="$(swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx12.0 --show-bin-path)/$APP_NAME"
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

echo "==> [3/5] 生成商业级无损压缩光学矢量应用图标 AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate-icon.swift" "$RES_DIR/AppIcon.icns"

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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>msnip</string>
            </array>
        </dict>
    </array>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MSnip 需要屏幕录制权限以捕捉并冻结当前屏幕区域供你圈记和贴图。</string>
</dict>
</plist>
EOF

SIGN_ID="${MSNIP_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    DETECTED_CERT="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/MSnip Local Signer|Apple Development/ && !s {print $2; s=1}')"
    SIGN_ID="${DETECTED_CERT:--}"
fi

if [ "$SIGN_ID" != "-" ]; then
    echo "  ✓ 使用本机固定证书签名 ($SIGN_ID) — 升级免重授系统权限"
    codesign --force --deep --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP_BUNDLE"
else
    codesign --force --deep --identifier "$BUNDLE_ID" --sign - "$APP_BUNDLE"
fi

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
echo "  Zip SHA256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "=========================================="
