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
TRACE="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Application Support/CarDash/ci-trace.log"
echo "[sim] launch (trace file: $TRACE)"
step "launch" xcrun simctl launch "$UDID" "$BID"

# 轮询 app 自己写的容器文件，不再碰 simctl 的日志管道
k=0; RES=quiet
while [ "$k" -lt 12 ]; do
  if [ -f "$TRACE" ]; then
    if grep -q "load finished" "$TRACE"; then RES=ok; break; fi
    if grep -q "load failed" "$TRACE"; then RES=fail; break; fi
    if grep -q "launched" "$TRACE"; then RES=started; fi
  fi
  sleep 5; k=$((k + 1))
done

echo "[sim] --- ci-trace.log ---"
if [ -f "$TRACE" ]; then cat "$TRACE"; else echo "[sim] trace file absent"; fi
echo "::notice::trace after $((k * 5))s (result=$RES): $(tr '\n' '|' < "$TRACE" 2>/dev/null || echo '<no file>')"

DETAIL=$(tail -1 "$TRACE" 2>/dev/null || echo "no trace file")
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl delete "$UDID" >/dev/null 2>&1 || true

echo "[sim] result=$RES ($DETAIL)"

case "$RES" in
  ok)   echo "::notice::sim smoke PASSED: $DETAIL" ;;
  *)
    echo "::error::sim smoke FAILED ($RES): $DETAIL"
    CR=$(ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i '^CarDash' | head -1 || true)
    if [ -n "$CR" ]; then
      echo "::error::crash report: $CR"
      python3 - "$HOME/Library/Logs/DiagnosticReports/$CR" <<'PY' 2>&1 | sed 's/^/::error::/' | head -14
import json, sys
raw = open(sys.argv[1]).read().split('\n', 1)
if len(raw) < 2:
    print('unexpected .ips layout:', raw[0][:300]); raise SystemExit
try:
    d = json.loads(raw[1])
except Exception as e:
    print('cannot parse .ips json:', e); print(raw[1][:500]); raise SystemExit
imgs = d.get('usedImages') or []
def nm(f):
    i = f.get('imageIndex'); s = f.get('symbol') or hex(f.get('imageOffset', 0))
    iname = imgs[i].get('name') if isinstance(i, int) and i < len(imgs) else None
    return (iname + ' ' if iname else '') + s
print('exception   :', d.get('exception'))
print('termination :', (d.get('termination') or {}).get('indicator'), (d.get('termination') or {}).get('details'))
print('reason      :', d.get('exceptionReason'))
leb = d.get('lastExceptionBacktrace') or []
if leb: print('EXC BACKTRACE:', ' < '.join(nm(f) for f in leb[:9]))
th = d.get('threads') or []
tg = [t for t in th if t.get('triggered')]
if tg: print('TRIGGERED:', ' < '.join(nm(f) for f in (tg[0].get('frames') or [])[:9]))
PY
    else
      echo "::error::no CarDash crash report in DiagnosticReports"
    fi
    exit 1 ;;
esac
