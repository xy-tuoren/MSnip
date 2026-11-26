#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MSnip"
VERSION="0.9.2"
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

BUILD_FLAGS=(-c release --product "$APP_NAME" -Xswiftc -Osize -Xswiftc -gnone -Xlinker -dead_strip)
SDK_VER="$(xcrun --show-sdk-version 2>/dev/null || echo 15.0)"
swift build "${BUILD_FLAGS[@]}"
ARM_SRC="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"
ARM_TMP="$DIST_DIR/${APP_NAME}_arm"
cp "$ARM_SRC" "$ARM_TMP"
/usr/bin/vtool -set-build-version macos 12.0 "$SDK_VER" -replace -output "$ARM_TMP" "$ARM_TMP" 2>/dev/null || true

FINAL_BIN="$DIST_DIR/${APP_NAME}_bin"
X86_TRIPLE=""
X86_MINOS="12.0"
if [ "$(uname -m)" = "arm64" ]; then
    if swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx12.0 >/dev/null 2>&1; then
        X86_TRIPLE="x86_64-apple-macosx12.0"
        X86_MINOS="12.0"
    elif swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx13.0 >/dev/null 2>&1; then
        X86_TRIPLE="x86_64-apple-macosx13.0"
        X86_MINOS="13.0"
    fi
fi
if [ -n "$X86_TRIPLE" ]; then
    X86_SRC="$(swift build "${BUILD_FLAGS[@]}" --triple "$X86_TRIPLE" --show-bin-path)/$APP_NAME"
    if [ -f "$X86_SRC" ] && [ "$(lipo -archs "$X86_SRC")" != "$(lipo -archs "$ARM_TMP")" ]; then
        X86_TMP="$DIST_DIR/${APP_NAME}_x86"
        cp "$X86_SRC" "$X86_TMP"
        /usr/bin/vtool -set-build-version macos "$X86_MINOS" "$SDK_VER" -replace -output "$X86_TMP" "$X86_TMP" 2>/dev/null || true
        lipo -create "$ARM_TMP" "$X86_TMP" -output "$FINAL_BIN"
        rm -f "$X86_TMP"
        if [ "$X86_MINOS" != "12.0" ]; then
            echo "  ✓ 已合成双架构 Universal Binary ($(lipo -archs "$FINAL_BIN"), arm64 minos 12.0 / x86_64 minos $X86_MINOS, SDK $SDK_VER)"
            echo "  ℹ 本机工具链缺少 x86_64 macOS 12 兼容库，已自动写入分架构最低版本声明（正式发版 CI macos-15 仍保持双 12.0）"
        else
            echo "  ✓ 已合成双架构 Universal Binary ($(lipo -archs "$FINAL_BIN"), SDK $SDK_VER)"
        fi
    else
        cp "$ARM_TMP" "$FINAL_BIN"
    fi
else
    cp "$ARM_TMP" "$FINAL_BIN"
    echo "  ✓ 已生成当前架构原生优化二进制 ($(lipo -archs "$FINAL_BIN"), SDK $SDK_VER)"
fi
rm -f "$ARM_TMP"

strip -rSTx "$FINAL_BIN" 2>/dev/null || strip -x "$FINAL_BIN" 2>/dev/null || true
cp "$FINAL_BIN" "$MACOS_DIR/$APP_NAME"
rm -f "$FINAL_BIN"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "==> [3/5] 生成商业级无损压缩光学矢量应用图标 AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate-icon.swift" "$RES_DIR/AppIcon.icns"

ARCH_MINOS_PLIST=""
if [ -n "$X86_TRIPLE" ] && [ "$X86_MINOS" != "12.0" ]; then
    ARCH_MINOS_PLIST="    <key>LSMinimumSystemVersionByArchitecture</key>
    <dict>
        <key>arm64</key>
        <string>12.0</string>
        <key>x86_64</key>
        <string>$X86_MINOS</string>
    </dict>
"
fi

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
${ARCH_MINOS_PLIST}    <key>LSUIElement</key>
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
