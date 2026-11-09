#!/bin/sh
# 冒烟测试：把 app 装进 iPad 模拟器、启动、断言 WKWebView 真的把线上页面加载完成。
# 每一步失败都要把命令自己的错误原文发成 ::error:: 注解 —— 匿名身份读不到 job 日志（403），
# 注解是唯一能拿回现场的通道，所以这里不能只报退出码。
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=CarDash
BID=com.oliverrovesik.cardash
SIM=$ROOT/app/build-sim
OUT=$SIM/$APP.app
DEPLOY=${DEPLOY_TARGET:-15.0}
UDID=""

die() { echo "::error::$1"; xcrun simctl delete "$UDID" >/dev/null 2>&1 || true; exit 1; }
step() {
  NAME=$1; shift
  echo "[sim] $NAME"
  set +e; "$@" 2>"$SIM/$NAME.err"; RC=$?; set -e
  if [ "$RC" -eq 0 ]; then return 0; fi
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
# 用 xcrun --sdk <name> 让 xcrun 自己配好工具链：手写 -sdk 只换了头文件系统，
# clang 会拿 macOS 的 sysroot 去 target iPhone，产出的二进制平台不对（platform 应为 7）
echo "[sim] compile for simulator"
set +e
xcrun --sdk iphonesimulator swiftc -O -target "arm64-apple-ios$DEPLOY-simulator" \
  -framework UIKit -framework WebKit -framework CoreLocation \
  -o "$OUT/$APP" "$ROOT"/app/Sources/*.swift 2>"$SIM/compile.err"
CRC=$?
set -e
if [ "$CRC" -ne 0 ]; then
  echo "::error::simulator compile failed (rc=$CRC)"
  head -12 "$SIM/compile.err" | sed 's/^/::error::/' || true
  exit 1
fi
BV=$(otool -l "$OUT/$APP" | grep -A4 LC_BUILD_VERSION | grep -E 'platform|minos' | tr -s ' \n' ' ')
echo "::notice::sim binary build version:$BV"
case "$BV" in *platform*7*) ;; *) echo "::error::simulator binary is not platform 7 (IOSSIMULATOR):$BV"; exit 1;; esac

cp "$ROOT/app/Info.plist" "$OUT/Info.plist"
printf 'APPL' > "$OUT/PkgInfo"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$OUT/Info.plist"
step "ad-hoc-sign" codesign --force --sign - "$OUT"

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

CAP=$SIM/app.log
: > "$CAP"
# 尝试 1：--console 让 simctl 把 app 的 stdout/stderr 打到它自己的 stdio，由 shell 重定向。
# （simctl launch 并不认 --stdout/--stderr：会被当成 destination，报 "Invalid device: --stdout"）
echo "[sim] launch attempt 1 (--console)"
xcrun simctl launch --console "$UDID" "$BID" >"$CAP" 2>&1 &
LP=$!
sleep 40
kill "$LP" >/dev/null 2>&1 || true
wait "$LP" 2>/dev/null || true

if ! grep -q CARDASH "$CAP"; then
  echo "[sim] attempt1 captured: $(head -3 "$CAP" | tr '\n' ' ')"
  echo "[sim] launch attempt 2 (plain launch + log stream)"
  xcrun simctl spawn "$UDID" log stream --style compact --level debug \
      --predicate 'eventMessage CONTAINS "CARDASH"' >"$SIM/stream.log" 2>&1 &
  SP=$!
  sleep 8
  set +e; xcrun simctl launch "$UDID" "$BID" 2>"$SIM/launch2.err"; L2=$?; set -e
  if [ "$L2" -ne 0 ]; then
    echo "::error::plain launch rc=$L2"
    head -5 "$SIM/launch2.err" | sed 's/^/::error::/' || true
  fi
  sleep 35
  kill "$SP" >/dev/null 2>&1 || true
  wait "$SP" 2>/dev/null || true
  cat "$SIM/stream.log" >> "$CAP"
fi

echo "[sim] --- captured app output (tail) ---"
tail -20 "$CAP" 2>/dev/null || echo "[sim] nothing captured"

RES=""; DETAIL=""
if grep -q "CARDASH: load finished" "$CAP" 2>/dev/null; then
  RES=ok; DETAIL=$(grep "CARDASH: load finished" "$CAP" | tail -1)
elif grep -q "CARDASH: load failed" "$CAP" 2>/dev/null; then
  RES=fail; DETAIL=$(grep "CARDASH: load failed" "$CAP" | tail -1)
elif grep -q "CARDASH: launched" "$CAP" 2>/dev/null; then
  RES=started; DETAIL="app launched but no navigation callback within the wait"
else
  RES=quiet; DETAIL="no CARDASH line captured by either launch path"
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
