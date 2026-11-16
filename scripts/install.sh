#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MSnip"
BUNDLE_ID="top.xy.msnip"
SRC_APP="$ROOT_DIR/dist/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ "${1:-}" = "--rebuild" ] || [ ! -d "$SRC_APP" ]; then
    echo "==> 构建最新 Release 应用包..."
    bash "$ROOT_DIR/scripts/bundle.sh"
fi

OLD_CDHASH=""
if [ -d "$DEST_APP" ]; then
    OLD_CDHASH="$(codesign -dvvv "$DEST_APP" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
fi
NEW_SIG_INFO="$(codesign -dvvv "$SRC_APP" 2>&1 || true)"
NEW_CDHASH="$(echo "$NEW_SIG_INFO" | awk -F= '/^CDHash=/ {print $2; exit}')"
IS_ADHOC="$(echo "$NEW_SIG_INFO" | grep -c '^Signature=adhoc' || true)"

echo "==> 停止正在运行的旧 $APP_NAME 实例..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

# 若使用临时 adhoc 签名且二进制哈希已变更，自动清理失效的僵尸 TCC 记录，避免系统设置残留假开启开关导致无法拖入
if [ "$IS_ADHOC" -gt 0 ] && [ -n "$OLD_CDHASH" ] && [ "$OLD_CDHASH" != "$NEW_CDHASH" ]; then
    echo "==> 检测到临时签名二进制更新，正在清理旧版失效的僵尸权限缓存..."
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
fi

echo "==> 安装至 ${DEST_APP} 并清理构建目录重复副本..."
rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"
xattr -cr "$DEST_APP" 2>/dev/null || true

# 移除 dist/MSnip.app 防止 LaunchServices / 系统设置将权限绑定到编译临时目录
"$LSREGISTER" -u "$SRC_APP" 2>/dev/null || true
rm -rf "$SRC_APP"
"$LSREGISTER" -f "$DEST_APP" 2>/dev/null || true

echo "==> 启动 ${DEST_APP} ..."
open "$DEST_APP"

echo "✅ 已安装并启动：${DEST_APP}"
if [ "$IS_ADHOC" -gt 0 ]; then
    echo "💡 提示：日常使用或重启电脑不会掉权限；若后续你经常重新编译源码，可运行一次 'bash scripts/setup-cert.sh' 生成本机固定证书，此后重编升级也永久免重授权限。"
fi
