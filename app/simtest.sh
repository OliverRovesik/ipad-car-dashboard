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

die() { echo "::error::$1"; tmo 30 xcrun simctl delete "$UDID" >/dev/null 2>&1 || true; exit 1; }
step() {
  NAME=$1; shift
  echo "[sim] $NAME"
  set +e; "$@" 2>"$SIM/$NAME.err"; RC=$?; set -e
  if [ "$RC" -eq 0 ]; then return 0; fi
  echo "::error::$NAME failed (rc=$RC)"
  head -8 "$SIM/$NAME.err" | sed 's/^/::error::/' || true
  die "$NAME aborted"
}
# runner 上的 CoreSimulator 服务会楔死：单条 simctl 调用可能永远不返回，
# 循环上限管不到它。看门狗到点 kill，把挂死变成一次普通的 step 失败。
tmo() {
  LIMIT=$1; shift
  "$@" & CMD=$!
  ( sleep "$LIMIT"; kill "$CMD" 2>/dev/null ) & WATCH=$!
  wait "$CMD"; RC=$?
  kill "$WATCH" 2>/dev/null
  wait "$WATCH" 2>/dev/null
  return $RC
}

mkdir -p "$SIM"
echo "[sim] devicetypes"
DT=$(tmo 30 xcrun simctl list devicetypes -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devicetypes"]
ip=[x["identifier"] for x in d if x["name"].startswith("iPad ")]
print(ip[0] if ip else "")' || true)
RT=$(tmo 30 xcrun simctl list runtimes -j | python3 -c 'import json,sys
rs=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable")]
ios=[r for r in rs if "SimRuntime.iOS" in r]
print(sorted(ios)[-1] if ios else "")' || true)
if [ -z "$DT" ] || [ -z "$RT" ]; then
  echo "::error::no iPad simulator runtime on this runner (devicetype=$DT runtime=$RT)"; exit 1
fi
echo "[sim] sim: $DT / $RT"

rm -rf "$SIM"; mkdir -p "$OUT"
# 用 xcrun --sdk <name> 让 xcrun 自己配好工具链：手写 -sdk 只换了头文件系统，
# clang 会拿 macOS 的 sysroot 去 target iPhone，产出的二进制平台不对（platform 应为 7）
echo "[sim] compile for simulator"
set +e
tmo 300 xcrun --sdk iphonesimulator swiftc -O -target "arm64-apple-ios$DEPLOY-simulator" \
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
step "icon" tmo 180 sh "$ROOT/app/icon.sh" iphonesimulator "$OUT" "$SIM/icon-partial.plist"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$OUT/Info.plist"
step "ad-hoc-sign" codesign --force --sign - "$OUT"

echo "[sim] create device"
UDID=$(tmo 60 xcrun simctl create cardash-smoke "$DT" "$RT" || true)
[ -n "$UDID" ] || die "simctl create returned no udid"
echo "[sim] boot $UDID"
step "boot" tmo 90 xcrun simctl boot "$UDID"
i=0; ST=""
while [ "$i" -lt 30 ]; do
  ST=$(tmo 25 xcrun simctl list devices -j | python3 -c "import json,sys
d=json.load(sys.stdin)['devices']
for rs in d.values():
    for x in rs:
        if x['udid']=='$UDID': print(x['state'])" || true)
  if [ "$ST" = "Booted" ]; then break; fi
  sleep 4; i=$((i + 1))
done
echo "[sim] state=$ST after $((i * 4))s"
[ "$ST" = "Booted" ] || die "simulator did not reach Booted (state=$ST)"

step "install" tmo 120 xcrun simctl install "$UDID" "$OUT"
BUNDLE=$(tmo 25 xcrun simctl get_app_container "$UDID" "$BID" app 2>/dev/null || true)
if [ -n "$BUNDLE" ]; then
  CAR=no; if [ -s "$BUNDLE/Assets.car" ]; then CAR=yes; fi
  echo "::notice::installed bundle icon: Assets.car=$CAR CFBundleIconName=$(plutil -extract CFBundleIconName raw "$BUNDLE/Info.plist" 2>/dev/null || echo missing)"
fi
# 容器路径别猜：iOS app 沙盒在 Devices/<UDID>/data/Containers/Data/Application/<UUID>/ 下面
CONT=$(tmo 25 xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null || true)
echo "[sim] data container: ${CONT:-<none returned>}"
TRACE=""
if [ -n "$CONT" ]; then TRACE="$CONT/Library/Application Support/CarDash/ci-trace.log"; fi
if [ ! -s "$TRACE" ]; then
  ALT=$(find "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data" -name ci-trace.log 2>/dev/null | head -1 || true)
  [ -n "$ALT" ] && TRACE="$ALT"
fi
echo "[sim] launch (trace file: $TRACE)"
step "launch" tmo 60 xcrun simctl launch "$UDID" "$BID"

# 模拟器里的 app 就是宿主机进程，pgrep 比任何日志管道都直接
ALIVE=no; if pgrep -f "CarDash.app/CarDash" >/dev/null 2>&1; then ALIVE=yes; fi

# 轮询 app 自己写的容器文件，不再碰 simctl 的日志管道
k=0; RES=quiet
while [ "$k" -lt 12 ]; do
  if [ -s "$TRACE" ]; then
    if grep -q "load finished" "$TRACE"; then RES=ok; break; fi
    if grep -q "load failed" "$TRACE"; then RES=fail; break; fi
    if grep -q "launched" "$TRACE"; then RES=started; fi
  fi
  sleep 5; k=$((k + 1))
done
ALIVE2=no; if pgrep -f "CarDash.app/CarDash" >/dev/null 2>&1; then ALIVE2=yes; fi
echo "::notice::alive after launch=$ALIVE, after $((k * 5))s=$ALIVE2, container=${CONT:-<none>}"

echo "[sim] --- ci-trace.log ---"
if [ -f "$TRACE" ]; then cat "$TRACE"; else echo "[sim] trace file absent"; fi
echo "::notice::trace after $((k * 5))s (result=$RES): $(tr '\n' '|' < "$TRACE" 2>/dev/null || echo '<no file>')"

DETAIL=$(tail -1 "$TRACE" 2>/dev/null || echo "no trace file")
tmo 30 xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
tmo 30 xcrun simctl delete "$UDID" >/dev/null 2>&1 || true

echo "[sim] result=$RES ($DETAIL)"

case "$RES" in
  ok)   echo "::notice::sim smoke PASSED: $DETAIL" ;;
  *)
    echo "::error::sim smoke FAILED ($RES): $DETAIL"
    sleep 10   # .ips 是异步落盘的，立刻找会扑空
    CRF=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/*.ips 2>/dev/null | head -25 \
          | xargs grep -l -i cardash 2>/dev/null | head -1 || true)
    if [ -n "$CRF" ]; then
      echo "::error::crash report: $CRF"
      python3 - "$CRF" <<'PY' 2>&1 | sed 's/^/::error::/' | head -14
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
