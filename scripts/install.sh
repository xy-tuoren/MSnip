#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MSnip"
SRC_APP="$ROOT_DIR/dist/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"

if [ "${1:-}" = "--rebuild" ] || [ ! -d "$SRC_APP" ]; then
    echo "==> 构建最新 Release 应用包..."
    bash "$ROOT_DIR/scripts/bundle.sh"
fi

echo "==> 停止正在运行的旧 $APP_NAME 实例..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

echo "==> 安装至 $DEST_APP ..."
rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"
xattr -cr "$DEST_APP" 2>/dev/null || true

echo "==> 启动 $DEST_APP ..."
open "$DEST_APP"

echo "✅ 已安装并启动：${DEST_APP}（现在可通过 Spotlight / Raycast 或快捷键直接使用）"
