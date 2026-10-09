#!/bin/bash
# AltairSim.app を作る。
#   使い方: Tools/make_app.sh [--universal] [--install]
#     --universal  arm64 と x86_64 の両方を含める(既定は、いま使っているマシンの向きだけ)
#     --install    作成後に ~/Applications へコピーする
#   出力: build/AltairSim.app(アドホック署名。自分のマシンで使う前提で、公証はしていない)
#   環境変数: BUNDLE_ID(既定 local.altairsim)、VERSION(既定 1.0)
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=0; INSTALL=0
for a in "$@"; do
    case "$a" in
        --universal) UNIVERSAL=1 ;;
        --install) INSTALL=1 ;;
        *) echo "不明な引数: $a" >&2; exit 2 ;;
    esac
done

BUNDLE_ID="${BUNDLE_ID:-local.altairsim}"
VERSION="${VERSION:-1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="build"
APP="$OUT/AltairSim.app"

ARCH_FLAGS=()
if [ "$UNIVERSAL" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> ビルド(release)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/AltairSim"
[ -x "$BIN" ] || { echo "実行ファイルが見つかりません: $BIN" >&2; exit 1; }

echo "==> アイコン"
mkdir -p "$OUT/icon"
python3 Tools/make_icon.py "$OUT/icon" >/dev/null

echo "==> バンドルを組み立て: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AltairSim"
cp "$OUT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleExecutable</key><string>AltairSim</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AltairSim</string>
    <key>CFBundleDisplayName</key><string>AltairSim</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Altair 8800 / 680b simulator</string>
</dict>
</plist>
PLIST

echo "==> 署名(アドホック)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 完了"
lipo -archs "$APP/Contents/MacOS/AltairSim" | sed 's/^/    アーキテクチャ: /'
du -sh "$APP" | sed 's/^/    サイズ: /'

if [ "$INSTALL" = 1 ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/AltairSim.app"
    cp -R "$APP" "$HOME/Applications/AltairSim.app"
    echo "    インストール: $HOME/Applications/AltairSim.app"
fi
