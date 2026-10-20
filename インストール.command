#!/bin/bash
# ダブルクリックで TaskTimer.app を作成して「アプリケーション」に入れ、起動します。
cd "$(dirname "$0")"
echo "=== TaskTimer をインストールします ==="

# 開発ツール（Command Line Tools）の確認
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo ""
  echo "Swiftのコンパイラが必要です。"
  echo "表示されるダイアログで「インストール」を押してください。"
  echo "完了したら、もう一度このファイルをダブルクリックしてください。"
  xcode-select --install 2>/dev/null
  read -n 1 -s -r -p "何かキーを押すと閉じます"
  exit 1
fi

set -e
pkill -x TaskTimer 2>/dev/null || true

BUILD="$(mktemp -d)"
APP="$BUILD/TaskTimer.app"
mkdir -p "$APP/Contents/MacOS"

echo "ビルド中…（1分ほどかかります）"
swiftc -O -parse-as-library TaskTimer.swift -o "$APP/Contents/MacOS/TaskTimer"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TaskTimer</string>
    <key>CFBundleDisplayName</key><string>TaskTimer</string>
    <key>CFBundleIdentifier</key><string>local.tasktimer</string>
    <key>CFBundleExecutable</key><string>TaskTimer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.7</string>
    <key>CFBundleVersion</key><string>17</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

# /Applications に入れる（書き込めなければ ~/Applications）
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
rm -rf "$DEST/TaskTimer.app"
cp -R "$APP" "$DEST/"
rm -rf "$BUILD"

open "$DEST/TaskTimer.app"
echo ""
echo "✅ $DEST/TaskTimer.app にインストールして起動しました。"
echo "   画面右上のメニューバーにタイマーのアイコンが出ています。"
echo "   このウインドウは閉じて大丈夫です。"
