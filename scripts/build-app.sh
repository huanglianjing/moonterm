#!/usr/bin/env bash
#
# 编译并组装 Moonterm.app。
#
#   bash scripts/build-app.sh            # release
#   bash scripts/build-app.sh debug      # debug
#
# 需要 Xcode（Swift 6 工具链）。只装了老版 Command Line Tools 会在 swift build 阶段失败。

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 变量一律带花括号：bash 3.2 会把紧跟其后的多字节字符（如「）」）并进变量名。
echo "==> 编译（${CONFIGURATION}）"
swift build -c "$CONFIGURATION" --product Moonterm
swift build -c "$CONFIGURATION" --product MoontermAskpass

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/Moonterm.app"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Moonterm" "$APP/Contents/MacOS/Moonterm"
# askpass 助手必须和主程序同目录：AskpassBridge.locateHelper() 就是这么找的。
cp "$BIN_DIR/MoontermAskpass" "$APP/Contents/MacOS/MoontermAskpass"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftTerm 带资源包（Metal shader）；SPM 生成的 Bundle.module 会在 Contents/Resources 里找它。
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "==> 临时签名（ad-hoc）"
codesign --force --sign - "$APP/Contents/MacOS/MoontermAskpass"
codesign --force --sign - "$APP"

echo "==> 完成：$APP"
echo "    运行：open \"$APP\""
