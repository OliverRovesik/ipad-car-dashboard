#!/bin/sh
# 冒烟测试：把 app 装进 iPad 模拟器、启动、断言 WKWebView 真的把线上页面加载完成。
# 每一步都打 [sim] 标记 —— 失败时 workflow 会把日志尾部逐行发成注解，
# 因为没有 token 的身份读不到 job 日志（403），注解是唯一能拿回现场的通道。
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=CarDash
BID=com.oliverrovesik.cardash
SIM=$ROOT/app/build-sim
OUT=$SIM/$APP.app
DEPLOY=${DEPLOY_TARGET:-15.0}

echo "[sim] devicetypes"
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
echo "[sim] sim: $DT / $RT"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
rm -rf "$SIM"; mkdir -p "$OUT"
echo "[sim] compile for simulator"
xcrun swiftc -O -sdk "$SDK" -target "arm64-apple-ios$DEPLOY-simulator" \
  -framework UIKit -framework WebKit -framework CoreLocation \
  -o "$OUT/$APP" "$ROOT"/app/Sources/*.swift
cp "$ROOT/app/Info.plist" "$OUT/Info.plist"
printf 'APPL' > "$OUT/PkgInfo"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$OUT/Info.plist"
echo "[sim] ad-hoc sign"
codesign --force --sign - "$OUT"

echo "[sim] create device"
UDID=$(xcrun simctl create cardash-smoke "$DT" "$RT")
echo "[sim] boot $UDID"
xcrun simctl boot "$UDID"
i=0
while [ "$i" -lt 30 ]; do
  ST=$(xcrun simctl list devices -j | python3 -c "import json,sys
d=json.load(sys.stdin)['devices']
for rs in d.values():
    for x in rs:
        if x['udid']=='$UDID': print(x['state'])")
  [ "$ST" = "Booted" ] && break
  sleep 4; i=$((i + 1))
done
echo "[sim] state=$ST after $((i * 4))s"

echo "[sim] install"
xcrun simctl install "$UDID" "$OUT"
# 注意选项必须写在 destination 之前，simctl 会把 destination 之后的东西当程序参数
echo "[sim] launch (capture stdout/stderr)"
xcrun simctl launch --stdout "$SIM/out.log" --stderr "$SIM/err.log" "$UDID" "$BID"

sleep 40
echo "[sim] --- app stderr (tail) ---"
tail -25 "$SIM/err.log" 2>/dev/null || echo "[sim] no stderr captured"

RES=""; DETAIL=""
if grep -q "CARDASH: load finished" "$SIM/err.log" 2>/dev/null; then
  RES=ok; DETAIL=$(grep "CARDASH: load finished" "$SIM/err.log" | tail -1)
elif grep -q "CARDASH: load failed" "$SIM/err.log" 2>/dev/null; then
  RES=fail; DETAIL=$(grep "CARDASH: load failed" "$SIM/err.log" | tail -1)
else
  RES=quiet; DETAIL="no CARDASH line in captured output"
fi
echo "[sim] captured lines: $(grep -c CARDASH "$SIM/err.log" 2>/dev/null || echo 0)"

xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
xcrun simctl delete "$UDID" 2>/dev/null || true

echo "[sim] result=$RES ($DETAIL)"
case "$RES" in
  ok)   echo "::notice::sim smoke PASSED: $DETAIL" ;;
  fail) echo "::error::sim smoke FAILED, page did not load: $DETAIL"; exit 1 ;;
  *)
    echo "::error::sim smoke inconclusive: $DETAIL — app likely died before launching"
    CR=$(ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i cardash | head -1 || true)
    if [ -n "$CR" ]; then
      echo "::error::crash report: $CR"
      grep -m6 -E "Exception Type|Termination Reason|Triggered by Thread|^CarDash" \
        ~/Library/Logs/DiagnosticReports/"$CR" 2>/dev/null | sed 's/^/::error::/'
    else
      echo "::error::no CarDash crash report found in DiagnosticReports"
    fi
    exit 1 ;;
esac
