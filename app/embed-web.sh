#!/bin/sh
# 把 app 默认页面和它依赖的 3 个本地文件打进 .app：启动时 WebContent.compose() 拼成自包含 HTML，
# 车的 base64 已经在 model/fiesta.data.js 里，所以整页零网络（只剩装饰性的天气 fetch）。
# 设备构建和模拟器构建共用这一份，避免两边拷贝清单漂移。
# 用法: sh app/embed-web.sh <app-dir>
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPDIR=$1
WEB="$APPDIR/web"

# 页面名只认 WebContent.swift 那一处真源：写死在这里的话，改了 app 加载哪个页面
# 却忘了改打包，启动就会 compose miss 回落到线上页面包，offline 直接白屏。
PAGE=$(sed -n 's/.*static let page = "\([^"]*\)".*/\1/p' "$ROOT/app/Sources/WebContent.swift")
if [ -z "$PAGE" ]; then
  echo "::error::embed-web: cannot read WebContent.page from app/Sources/WebContent.swift"; exit 1
fi

mkdir -p "$WEB/vendor" "$WEB/model"
TOTAL=0
for f in "$PAGE" vendor/three.min.js vendor/GLTFLoader.js model/fiesta.data.js; do
  SRC="$ROOT/$f"
  if [ ! -s "$SRC" ]; then
    echo "::error::embed-web: missing source $f"; exit 1
  fi
  cp "$SRC" "$WEB/$f"
  S=$(wc -c < "$SRC" | tr -d ' ')
  D=$(wc -c < "$WEB/$f" | tr -d ' ')
  if [ "$S" != "$D" ]; then
    echo "::error::embed-web: $f size mismatch src=$S dst=$D"; exit 1
  fi
  TOTAL=$((TOTAL + D))
done
echo "::notice::embedded web bytes=$TOTAL files=4"