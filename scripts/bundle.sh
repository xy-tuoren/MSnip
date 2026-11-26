#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MSnip"
VERSION="0.9.3"
BUNDLE_ID="top.xy.msnip"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

UNIVERSAL="${MSNIP_UNIVERSAL:-0}"
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --native)    UNIVERSAL=0 ;;
        *)
            echo "❌ 未知参数: $arg（支持 --native / --universal）" >&2
            exit 1
            ;;
    esac
done

echo "==> [1/5] 运行单文件行数守门检查 (≤ 800 行)..."
OVER_LIMIT=0
while IFS= read -r file; do
    lines=$(wc -l < "$file" | tr -d ' ')
    if [ "$lines" -gt 800 ]; then
        echo "  ❌ 超出 800 行硬护栏: $file ($lines 行)"
        OVER_LIMIT=1
    fi
done < <(find Sources -name '*.swift')
if [ "$OVER_LIMIT" -ne 0 ]; then
    exit 1
fi
echo "  ✓ 所有 Swift 源文件均符合 ≤ 800 行护栏"

echo "==> [2/5] 构建 Release 二进制 (-Osize + 单单元 LLVM 优化 + 符号表裁剪)..."
rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# 保留完整 Swift 反射元数据以确保 SwiftUI / Translation / VisionKit 运行期 100% 安全，
# 通过单 LLVM 单元合并 + 跨模块优化 + 仅导出 _main 实现极致瘦身。
BUILD_FLAGS=(
    -c release --product "$APP_NAME"
    -Xswiftc -Osize
    -Xswiftc -gnone
    -Xswiftc -cross-module-optimization
    -Xswiftc -Xfrontend -Xswiftc -enable-single-module-llvm-emission
    -Xswiftc -Xfrontend -Xswiftc -internalize-at-link
    -Xlinker -dead_strip
    -Xlinker -dead_strip_dylibs
    -Xlinker -x
    -Xlinker -exported_symbol -Xlinker _main
)
SDK_VER="$(xcrun --show-sdk-version 2>/dev/null || echo 15.0)"
HOST_ARCH="$(uname -m)"

swift build "${BUILD_FLAGS[@]}"
NATIVE_SRC="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"
NATIVE_TMP="$DIST_DIR/${APP_NAME}_${HOST_ARCH}"
cp "$NATIVE_SRC" "$NATIVE_TMP"
/usr/bin/vtool -set-build-version macos 12.0 "$SDK_VER" -replace -output "$NATIVE_TMP" "$NATIVE_TMP" 2>/dev/null || true

FINAL_BIN="$DIST_DIR/${APP_NAME}_bin"
X86_MINOS="12.0"

if [ "$UNIVERSAL" = "1" ]; then
    if [ "$HOST_ARCH" = "arm64" ]; then
        OTHER_ARCH="x86_64"
    elif [ "$HOST_ARCH" = "x86_64" ]; then
        OTHER_ARCH="arm64"
    else
        echo "  ❌ 不支持的宿主机架构: $HOST_ARCH" >&2
        exit 1
    fi

    CROSS_LOG="$DIST_DIR/cross_build.log"
    OTHER_TRIPLE=""
    OTHER_MINOS="12.0"
    if swift build "${BUILD_FLAGS[@]}" --triple "${OTHER_ARCH}-apple-macosx12.0" >"$CROSS_LOG" 2>&1; then
        OTHER_TRIPLE="${OTHER_ARCH}-apple-macosx12.0"
    elif [ "$OTHER_ARCH" = "x86_64" ] && swift build "${BUILD_FLAGS[@]}" --triple "x86_64-apple-macosx13.0" >"$CROSS_LOG" 2>&1; then
        OTHER_TRIPLE="x86_64-apple-macosx13.0"
        OTHER_MINOS="13.0"
        X86_MINOS="13.0"
    else
        echo "  ❌ --universal 交叉编译 ${OTHER_ARCH} 失败（禁止静默回退单架构）：" >&2
        cat "$CROSS_LOG" >&2
        rm -f "$CROSS_LOG" "$NATIVE_TMP"
        exit 1
    fi
    rm -f "$CROSS_LOG"

    OTHER_SRC="$(swift build "${BUILD_FLAGS[@]}" --triple "$OTHER_TRIPLE" --show-bin-path)/$APP_NAME"
    if [ ! -f "$OTHER_SRC" ]; then
        echo "  ❌ 未找到交叉编译产物: $OTHER_SRC" >&2
        rm -f "$NATIVE_TMP"
        exit 1
    fi
    OTHER_TMP="$DIST_DIR/${APP_NAME}_${OTHER_ARCH}"
    cp "$OTHER_SRC" "$OTHER_TMP"
    /usr/bin/vtool -set-build-version macos "$OTHER_MINOS" "$SDK_VER" -replace -output "$OTHER_TMP" "$OTHER_TMP" 2>/dev/null || true

    lipo -create "$NATIVE_TMP" "$OTHER_TMP" -output "$FINAL_BIN"
    rm -f "$OTHER_TMP"
    BUILT_ARCHS="$(lipo -archs "$FINAL_BIN")"
    if [[ "$BUILT_ARCHS" != *"arm64"* ]] || [[ "$BUILT_ARCHS" != *"x86_64"* ]]; then
        echo "  ❌ Universal Binary 架构校验失败: $BUILT_ARCHS" >&2
        rm -f "$NATIVE_TMP" "$FINAL_BIN"
        exit 1
    fi
    if [ "$X86_MINOS" != "12.0" ]; then
        echo "  ✓ 已合成双架构 Universal Binary ($BUILT_ARCHS, arm64 minos 12.0 / x86_64 minos $X86_MINOS, SDK $SDK_VER)"
        echo "  ℹ 本机工具链缺少 x86_64 macOS 12 兼容库，已自动写入分架构最低版本声明（正式发版 CI macos-15 仍保持双 12.0）"
    else
        echo "  ✓ 已合成双架构 Universal Binary ($BUILT_ARCHS, SDK $SDK_VER)"
    fi
else
    cp "$NATIVE_TMP" "$FINAL_BIN"
    echo "  ✓ 已生成当前架构原生极致瘦身二进制 ($(lipo -archs "$FINAL_BIN"), SDK $SDK_VER)"
fi
rm -f "$NATIVE_TMP"

strip "$FINAL_BIN" 2>/dev/null || strip -x "$FINAL_BIN" 2>/dev/null || true
cp "$FINAL_BIN" "$MACOS_DIR/$APP_NAME"
rm -f "$FINAL_BIN"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "==> [3/5] 生成纯矢量高压缩应用图标 AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate-icon.swift" "$RES_DIR/AppIcon.icns"

ARCH_MINOS_PLIST=""
if [ "$UNIVERSAL" = "1" ] && [ "$X86_MINOS" != "12.0" ]; then
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
if [ "$UNIVERSAL" = "1" ]; then
    ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macOS.zip"
    SIZE_LIMIT_KB=6656
else
    ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macOS-${HOST_ARCH}.zip"
    SIZE_LIMIT_KB=3072
fi
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

APP_KB="$(du -sk "$APP_BUNDLE" | awk '{print $1}')"
if [ "$APP_KB" -gt "$SIZE_LIMIT_KB" ]; then
    echo "  ❌ App 体积超标: ${APP_KB} KB > ${SIZE_LIMIT_KB} KB" >&2
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ 打包完成！"
echo "  App 路径: $APP_BUNDLE"
echo "  二进制架构: $(file "$MACOS_DIR/$APP_NAME" | sed 's/.*: //')"
echo "  图标大小: $(du -sh "$RES_DIR/AppIcon.icns" | awk '{print $1}')"
echo "  App 总大小: $(du -sh "$APP_BUNDLE" | awk '{print $1}') (${APP_KB} KB ≤ ${SIZE_LIMIT_KB} KB)"
echo "  Zip 包大小: $(du -sh "$ZIP_PATH" | awk '{print $1}') ($(basename "$ZIP_PATH"))"
echo "  Zip SHA256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "=========================================="
