#!/bin/sh
# 冒烟测试：把 app 装进 iPad 模拟器、启动、断言 WKWebView 真的把线上页面加载完成。
# 每一步失败都要把命令自己的错误原文发成 ::error:: 注解 —— 没有 token 的身份读不到
# job 日志（403），注解是唯一能拿回现场的通道，所以这里不能只报退出码。
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=CarDash
BID=com.oliverrovesik.cardash
SIM=$ROOT/app/build-sim
OUT=$SIM/$APP.app
DEPLOY=${DEPLOY_TARGET:-15.0}
UDID=""

die() { echo "::error::$1"; xcrun simctl delete "$UDID" >/dev/null 2>&1 || true; exit 1; }
# 跑一条命令，失败时把它的 stderr 原文逐行发成注解
step() {
  NAME=$1; shift
  echo "[sim] $NAME"
  if "$@" 2>"$SIM/$NAME.err"; then return 0; fi
  RC=$?
  echo "::error::$NAME failed (rc=$RC)"
  head -8 "$SIM/$NAME.err" | sed 's/^/::error::/' || true
  die "$NAME aborted"
}

mkdir -p "$SIM"
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

rm -rf "$SIM"; mkdir -p "$OUT"
# 用 xcrun --sdk <name> 让 xcrun 自己配好工具链：上一版手写 -sdk 路径时 clang 报
# "using sysroot for 'MacOSX' but targeting 'iPhone'"，产出的二进制被模拟器拒收
echo "[sim] compile for simulator"
if ! xcrun --sdk iphonesimulator swiftc -O -target "arm64-apple-ios$DEPLOY-simulator" \
     -framework UIKit -framework WebKit -framework CoreLocation \
     -o "$OUT/$APP" "$ROOT"/app/Sources/*.swift 2>"$SIM/compile.err"; then
  RC=$?
  echo "::error::simulator compile failed (rc=$RC)"
  head -12 "$SIM/compile.err" | sed 's/^/::error::/' || true
  exit 1
fi
grep -i "sysroot" "$SIM/compile.err" >/dev/null 2>&1 && echo "::error::compile still warns about sysroot: $(head -2 "$SIM/compile.err")"
echo "::notice::sim binary build version: $(otool -l "$OUT/$APP" | grep -A4 LC_BUILD_VERSION | grep -E 'platform|minos' | tr -s ' \\n' ' ')"

cp "$ROOT/app/Info.plist" "$OUT/Info.plist"
printf 'APPL' > "$OUT/PkgInfo"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$OUT/Info.plist"
step "ad-hoc sign" codesign --force --sign - "$OUT"

echo "[sim] create device"
UDID=$(xcrun simctl create cardash-smoke "$DT" "$RT")
echo "[sim] boot $UDID"
xcrun simctl boot "$UDID"
i=0; ST=""
while [ "$i" -lt 30 ]; do
  ST=$(xcrun simctl list devices -j | python3 -c "import json,sys
d=json.load(sys.stdin)['devices']
for rs in d.values():
    for x in rs:
        if x['udid']=='$UDID': print(x['state'])")
  if [ "$ST" = "Booted" ]; then break; fi
  sleep 4; i=$((i + 1))
done
echo "[sim] state=$ST after $((i * 4))s"
[ "$ST" = "Booted" ] || die "simulator did not reach Booted (state=$ST)"

step "install" xcrun simctl install "$UDID" "$OUT"
# 注意 simctl 的选项必须写在 destination 之前，之后的参数会被当成 app 的启动参数
step "launch" xcrun simctl launch --stdout "$SIM/out.log" --stderr "$SIM/err.log" "$UDID" "$BID"

sleep 40
echo "[sim] --- app stderr (tail) ---"
tail -20 "$SIM/err.log" 2>/dev/null || echo "[sim] no stderr captured"

RES=""; DETAIL=""
if grep -q "CARDASH: load finished" "$SIM/err.log" 2>/dev/null; then
  RES=ok; DETAIL=$(grep "CARDASH: load finished" "$SIM/err.log" | tail -1)
elif grep -q "CARDASH: load failed" "$SIM/err.log" 2>/dev/null; then
  RES=fail; DETAIL=$(grep "CARDASH: load failed" "$SIM/err.log" | tail -1)
elif grep -q "CARDASH: launched" "$SIM/err.log" 2>/dev/null; then
  RES=started; DETAIL="app launched but no navigation callback within 40s"
else
  RES=quiet; DETAIL="no CARDASH line in captured output"
fi
echo "[sim] result=$RES ($DETAIL)"

xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl delete "$UDID" >/dev/null 2>&1 || true

case "$RES" in
  ok)   echo "::notice::sim smoke PASSED: $DETAIL" ;;
  *)
    echo "::error::sim smoke FAILED ($RES): $DETAIL"
    CR=$(ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i cardash | head -1 || true)
    if [ -n "$CR" ]; then
      echo "::error::crash report: $CR"
      grep -m5 -E "Exception Type|Termination Reason|Triggered by Thread" \
        ~/Library/Logs/DiagnosticReports/"$CR" 2>/dev/null | sed 's/^/::error::/' || true
    else
      echo "::error::no CarDash crash report in DiagnosticReports"
    fi
    exit 1 ;;
esac
