#!/bin/sh
# 把单尺寸 1024 图标编成 Assets.car 并把 actool 的 partial plist 合并进 bundle 的 Info.plist。
# 手工 swiftc 装配没有 xcodebuild 代劳这一步；legacy CFBundleIconFiles 在新系统上不可靠，走 asset catalog。
# 用法: sh app/icon.sh <iphoneos|iphonesimulator> <app-dir> <partial-plist-out>
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLAT=$1; APPDIR=$2; PART=$3
DEPLOY=${DEPLOY_TARGET:-15.0}

xcrun actool "$ROOT/app/Assets.xcassets" --compile "$APPDIR" --app-icon AppIcon \
  --output-partial-info-plist "$PART" --platform "$PLAT" \
  --minimum-deployment-target "$DEPLOY" --target-device ipad

python3 - "$APPDIR/Info.plist" "$PART" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: d = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: p = plistlib.load(f)
d.update(p)
with open(sys.argv[1], 'wb') as f: plistlib.dump(d, f)
print('icon keys merged:', sorted(p))
PY

if [ ! -s "$APPDIR/Assets.car" ]; then
  echo "::error::Assets.car missing after actool"; exit 1
fi
ICON_NAME=$(plutil -extract CFBundleIconName raw "$APPDIR/Info.plist" 2>/dev/null || true)
if [ -z "$ICON_NAME" ]; then
  echo "::error::CFBundleIconName missing after merge; home screen would show no icon"; exit 1
fi
echo "::notice::icon compiled: Assets.car $(wc -c < "$APPDIR/Assets.car" | tr -d ' ') bytes, CFBundleIconName=$ICON_NAME"