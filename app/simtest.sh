#!/bin/sh
# 冒烟测试：把 app 装进 iPad 模拟器、启动、断言 WKWebView 真的把线上页面加载完成。
# 结论一律通过 ::error:: / ::notice:: 注解输出 —— 匿名身份读不到 job 日志（403），
# 注解是唯一能拿回结果的通道，所以这里不要指望日志，看注解。
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=CarDash
BID=com.oliverrovesik.cardash
SIM=$ROOT/app/build-sim
OUT=$SIM/$APP.app
DEPLOY=${DEPLOY_TARGET:-15.0}

DT=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devicetypes"]
ip=[x["identifier"] for x in d if x["name"].startswith("iPad ")]
print(ip[0] if ip else "")')
RT=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys
rs=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable")]
ios=[r for r in rs if "SimRuntime.iOS" in r]
print(sorted(ios)[-1] if ios else "")')
if [ -z "$DT" ] || [ -z "$RT" ]; then
  echo "::error::no iPad simulator runtime on this runner (devicetype=$DT runtime=$RT)"; exit 1
fi
echo "sim: $DT / $RT"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
rm -rf "$SIM"; mkdir -p "$OUT"
xcrun swiftc -O -sdk "$SDK" -target "arm64-apple-ios$DEPLOY-simulator" \
  -framework UIKit -framework WebKit -framework CoreLocation \
  -o "$OUT/$APP" "$ROOT"/app/Sources/*.swift
cp "$ROOT/app/Info.plist" "$OUT/Info.plist"
printf 'APPL' > "$OUT/PkgInfo"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$OUT/Info.plist"
codesign --force --sign - --timestamp=none "$OUT"

UDID=$(xcrun simctl create cardash-smoke "$DT" "$RT")
xcrun simctl boot "$UDID" --timeout 240
xcrun simctl install "$UDID" "$OUT"
xcrun simctl launch "$UDID" "$BID"

i=0; RES=""; DETAIL=""
while [ "$i" -lt 14 ]; do
  sleep 5; i=$((i + 1))
  LOG=$(xcrun simctl spawn "$UDID" log show --style compact --last 3m \
        --predicate 'eventMessage CONTAINS "CARDASH"' 2>/dev/null || true)
  if echo "$LOG" | grep -q "CARDASH: load finished"; then
    RES=ok; DETAIL=$(echo "$LOG" | grep "load finished" | tail -1); break
  fi
  if echo "$LOG" | grep -q "CARDASH: load failed"; then
    RES=fail; DETAIL=$(echo "$LOG" | grep "load failed" | tail -1); break
  fi
done
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
xcrun simctl delete "$UDID" 2>/dev/null || true

case "$RES" in
  ok)   echo "::notice::sim smoke PASSED after $((i * 5))s: $DETAIL" ;;
  fail) echo "::error::sim smoke FAILED, page did not load: $DETAIL"; exit 1 ;;
  *)    echo "::error::sim smoke inconclusive: no CARDASH log line in 70s (app may not have launched)"; exit 1 ;;
esac
