#!/bin/sh
# NemoNotch 变异验证 — 把修复/护栏改回去,要求测试变红(假测试判据的机器版)。
# 动机:AGENTS.md Testing 的判别剃刀是人工判断;本脚本把它变成一条命令的证据
# (「每个新护栏先变异验证再信」,2026-10-20 起,镜像 DynamicIsland 的规矩)。
#
# Usage:
#   sh scripts/mutate.sh <swift文件> <原文> <替换文> [--only TestClass]
#   路径相对仓库根;原文/替换文按字面量处理(python3 精确替换,非正则,只换第一处)。
#
# 判定(退出码即证据,日志路径见 test.sh 输出):
#   0  测试变红          → ✅ 变异被抓住,这条护栏有鉴别力
#   1  测试仍绿          → ❌ 变异存活,这条护栏没有牙齿(假测试判据命中)
#   2  0 用例/原文缺失/基础设施失败 → 不构成「抓住」,先修过滤器或换变异点
#
# 铁律:无论结果如何、无论中途怎么退出(含 Ctrl-C),文件必定恢复变异前的
# 原始字节(备份走 cp,不走 git — 未提交改动也原样恢复,脏文件安全)。
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

usage() {
  echo "usage: sh scripts/mutate.sh <swift文件> <原文> <替换文> [--only <TestClass>]" >&2
  exit 2
}

[ $# -ge 3 ] || usage
file="$1"; orig="$2"; repl="$3"; shift 3
only_class=""
if [ $# -gt 0 ]; then
  [ "$1" = "--only" ] && [ $# -ge 2 ] || usage
  only_class="$2"
fi

[ -f "$file" ] || { echo "❌ 文件不存在(相对仓库根): $file" >&2; exit 2; }

# ── 备份 + 必定恢复:trap 兜住正常退出与信号,恢复函数幂等 ──
bak="$file.nemonotch-mutate.bak"
restored=0
restore() {
  if [ "$restored" = 0 ] && [ -f "$bak" ]; then
    mv "$bak" "$file"
    restored=1
    echo "🔁 已恢复原文件: $file"
  fi
}
trap restore EXIT
trap 'restore; exit 130' INT
trap 'restore; exit 143' TERM

cp "$file" "$bak"

# ── 注入变异(python3 字面量替换,与 xcstrings.py 同款依赖)──
if ! python3 - "$file" "$orig" "$repl" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old, new = sys.argv[2], sys.argv[3]
if old not in text:
    print(f"❌ 原文未找到(字面量,非正则): {old!r}", file=sys.stderr)
    sys.exit(2)
if old == new:
    print("❌ 原文与替换文相同 — 这不是变异", file=sys.stderr)
    sys.exit(2)
p.write_text(text.replace(old, new, 1))
PY
then
  exit 2
fi
echo "🧬 已注入变异: $file"
echo "   $orig  →  $repl"

# ── 跑测试:复用 test.sh(签名 flags / 日志 / 零用例守卫全继承)──
# 输出落临时文件再 cat:POSIX sh 管道拿不到退出码,退出码正是要判定的证据。
tmp=$(mktemp)
if [ -n "$only_class" ]; then
  echo "🧪 sh scripts/test.sh --only $only_class"
  sh scripts/test.sh --only "$only_class" >"$tmp" 2>&1
else
  echo "🧪 sh scripts/test.sh(全部)"
  sh scripts/test.sh >"$tmp" 2>&1
fi
status=$?
cat "$tmp"

# ── 解析判定(先解析后删临时文件)──
counts=$(sed -n 's/.*通过 \([0-9][0-9]*\) · 失败 \([0-9][0-9]*\).*/\1 \2/p' "$tmp" | tail -1)
# 零用例守卫的报错不在摘要行里,单独探测(它出现时 test.sh 已自行 exit 1)
grep_zero=$(grep -c '没有任何用例被执行' "$tmp" 2>/dev/null || true)
rm -f "$tmp"
[ -n "$counts" ] || counts="0 0"
passed=${counts% *}
failed=${counts#* }

if [ "$status" != 0 ] && [ "${failed:-0}" -gt 0 ]; then
  echo ""
  echo "✅ 变异被抓住:测试变红(失败 ${failed} 个,通过 ${passed})— 这条护栏有鉴别力。"
  echo "   证据:退出码 $status;完整日志路径见上方 test.sh 输出。"
  exit 0
elif [ "${grep_zero:-0}" -ge 1 ]; then
  echo ""
  echo "❌ 0 个用例被执行(--only 拼错/测试 target 接线断裂)— 不构成「抓住」,先修过滤器" >&2
  exit 2
elif [ "$status" != 0 ]; then
  echo ""
  echo "⚠️ 测试非零退出但没有可解析的失败用例 — 可能是变异导致编译失败(构造层拦住,也算有效)," >&2
  echo "   也可能是基础设施问题;请看日志确认后再下结论。" >&2
  exit 2
else
  echo ""
  echo "❌ 变异存活:测试全绿(通过 ${passed})— 这条护栏没有牙齿。" >&2
  echo "   假测试判据:被测代码返回默认值也会过的测试没有鉴别力(AGENTS.md Testing)。" >&2
  echo "   给它喂具体输入、断言字面输出;或承认该路径无法廉价测试并明说。" >&2
  exit 1
fi
