#!/usr/bin/env bash
# 发版后运行：下载 GitHub Release 上实际发布的 Universal Zip，把它的版本号与 SHA256 写进 Casks/msnip.rb。
#
# 哈希必须取自用户实际会下载的那个文件：Release 里的 Universal 包由 CI 构建，
# 本机重新打包得到的 Zip 字节不同，用本机哈希会让所有 brew 用户安装失败。
#
# 用法：bash scripts/update-cask.sh [版本号]   # 省略时读取 scripts/bundle.sh 中的 VERSION
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT_DIR/Casks/msnip.rb"

VERSION="${1:-$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT_DIR/scripts/bundle.sh" | head -n 1)}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "❌ 无效版本号: '$VERSION'" >&2
    exit 1
fi

URL_TEMPLATE="$(sed -n 's/^  url "\(.*\)"$/\1/p' "$CASK" | head -n 1)"
if [ -z "$URL_TEMPLATE" ]; then
    echo "❌ 未能从 $CASK 读取 url 行" >&2
    exit 1
fi
URL="${URL_TEMPLATE//\#\{version\}/$VERSION}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ZIP="$TMP_DIR/release.zip"

echo "==> 下载线上发布包: $URL"
curl -fsSL --retry 3 --proto '=https' -o "$ZIP" "$URL"

ZIP_VERSION="$(unzip -p "$ZIP" "MSnip.app/Contents/Info.plist" 2>/dev/null \
    | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null || true)"
if [ "$ZIP_VERSION" != "$VERSION" ]; then
    echo "❌ 包内 App 版本 '${ZIP_VERSION:-无法读取}' 与目标版本 '$VERSION' 不一致，未修改 Cask" >&2
    exit 1
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [[ ! "$SHA" =~ ^[0-9a-f]{64}$ ]]; then
    echo "❌ SHA256 计算失败: '$SHA'" >&2
    exit 1
fi

sed -E \
    -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
    -e "s/^  sha256 .*$/  sha256 \"$SHA\"/" \
    "$CASK" > "$TMP_DIR/msnip.rb"

if ! grep -qx "  version \"$VERSION\"" "$TMP_DIR/msnip.rb" || ! grep -qx "  sha256 \"$SHA\"" "$TMP_DIR/msnip.rb"; then
    echo "❌ Cask 中未找到 version / sha256 行，未修改" >&2
    exit 1
fi
cat "$TMP_DIR/msnip.rb" > "$CASK"

echo "✅ 已更新 Casks/msnip.rb"
echo "  version: $VERSION"
echo "  sha256:  $SHA"
echo "  记得提交该文件；之后若重新上传了同名 Zip，需要再运行一次本脚本。"
