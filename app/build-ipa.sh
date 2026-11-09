#!/bin/sh
# 在任意装有 Xcode 的 Mac 上构建未签名 .ipa：sh app/build-ipa.sh
# 未签名是故意的 —— 签名方式（Sideloadly / 企业证书 / TestFlight）由使用者决定，构建产物不该绑定某一把私钥。
set -eu

APP_NAME=CarDash
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT_DIR:-$ROOT/app/build}
APP="$OUT/Payload/$APP_NAME.app"
DEPLOY=${DEPLOY_TARGET:-15.0}

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "SDK: $SDK"

rm -rf "$OUT"
mkdir -p "$APP"

xcrun swiftc -O -sdk "$SDK" -target "arm64-apple-ios$DEPLOY" \
  -framework UIKit -framework WebKit -framework CoreLocation \
  -o "$APP/$APP_NAME" "$ROOT"/app/Sources/*.swift

cp "$ROOT/app/Info.plist" "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
printf 'LC_BUILD_VERSION: '; otool -l "$APP/$APP_NAME" | grep -A4 LC_BUILD_VERSION | grep -E 'platform|minos' | tr -s ' '
printf 'arch: '; lipo -archs "$APP/$APP_NAME" 2>/dev/null || file "$APP/$APP_NAME"

(cd "$OUT" && rm -f "$APP_NAME-unsigned.ipa" && zip -qry "$APP_NAME-unsigned.ipa" Payload)
echo "ipa: $OUT/$APP_NAME-unsigned.ipa"
ls -la "$OUT/$APP_NAME-unsigned.ipa"
