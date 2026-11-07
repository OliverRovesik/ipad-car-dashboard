#!/bin/sh
# 用假 GATT 设备回归测试 probe.html，不需要真实适配器。
# hash 可选：ffe0 | nus | p18f0 | odd | hidden
# 每次生成都给 fake.js 带时间戳，否则浏览器会复用旧替身，测试结果不可信。
set -e
cd "$(dirname "$0")/.."
TS=$(date +%s)
python3 - "$TS" <<'PY'
import sys
s = open("probe.html", encoding="utf-8").read()
s = s.replace("</body>", '<script src="fake.js?v=%s"></script>\n</body>' % sys.argv[1])
open("selftest/preview.html", "w", encoding="utf-8").write(s)
print("preview.html 已生成 -> fake.js?v=%s" % sys.argv[1])
PY
echo "浏览器打开： http://localhost:8000/selftest/preview.html#ffe0"
exec python3 -m http.server 8000
