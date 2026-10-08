#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH_ARGS=(--arch "$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
elif [[ $# -ne 0 ]]; then
    printf '用法：bash scripts/build-app.sh [--universal]\n' >&2
    exit 2
fi
swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"
APP="$PWD/dist/AI落地安全检测.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NetworkWatch" "$APP/Contents/MacOS/NetworkWatch"
# 去掉包含开发机器路径的调试符号，随后重新进行 ad-hoc 签名。
/usr/bin/strip -S "$APP/Contents/MacOS/NetworkWatch"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# 同时提供现代系统界面使用的资产目录和传统 .icns 图标。
ASSET_WORK="$(mktemp -d "$PWD/.build/app-assets.XXXXXX")"
CATALOG="$ASSET_WORK/AppAssets.xcassets"
mkdir -p "$CATALOG"
iconutil -c iconset resources/AppIcon.icns -o "$ASSET_WORK/AppIcon.iconset"
mv "$ASSET_WORK/AppIcon.iconset" "$CATALOG/AppIcon.appiconset"
python3 - "$CATALOG" <<'PY'
from pathlib import Path
import json
import sys

catalog = Path(sys.argv[1])
info = {'version': 1, 'author': 'xcode'}
(catalog / 'Contents.json').write_text(json.dumps({'info': info}))
images = [
    {'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x',
     'filename': f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'}
    for size in [16, 32, 128, 256, 512] for scale in [1, 2]
]
(catalog / 'AppIcon.appiconset/Contents.json').write_text(json.dumps({'images': images, 'info': info}))
PY
xcrun actool "$CATALOG" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_WORK/asset-info.plist" --output-format human-readable-text
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
touch "$APP"
printf '已构建：%s\n' "$APP"
