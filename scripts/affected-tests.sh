#!/bin/sh
# affected-tests.sh — 确定性影响面测试选择(「能硬化的都硬化」)。
# 背景:--only 的类名曾由 agent 挑选,出过选错类的假绿;ripwire --affected 对
# Swift Testing 的宏风格测试解析不了(实测 tests=0),故自建映射,零判断:
#   改动的生产 .swift → 顶层符号(class/struct/enum/protocol/extension/func/typealias)
#   → NemoNotchTests/ 中引用了任一符号的测试文件(文件名即类名)
#   + 改动的测试文件自身
#   → test.sh --only <逗号列表>
# 映射为空 → 回落全量(宁多跑,不漏跑)。同名符号误吸只会多跑,方向安全。
#
# Usage:
#   sh scripts/affected-tests.sh                    # 在 feature worktree 里,base=develop
#   sh scripts/affected-tests.sh <base>             # 指定对照基线
#   sh scripts/affected-tests.sh --files F1,F2      # 覆盖改动集(验证/探针用)
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

base="develop"
override_files=""
while [ $# -gt 0 ]; do
  case "$1" in
    --files) [ $# -ge 2 ] || { echo "usage: affected-tests.sh [base] [--files F1,F2]" >&2; exit 2; }
             override_files="$2"; shift 2 ;;
    *) base="$1"; shift ;;
  esac
done

if [ -n "$override_files" ]; then
  changed_prod=$(echo "$override_files" | tr ',' '\n' | grep -E '^NemoNotch/.*\.swift$' || true)
  changed_tests=$(echo "$override_files" | tr ',' '\n' | grep -E '^NemoNotchTests/.*\.swift$' || true)
else
  if ! git rev-parse --verify --quiet "$base" >/dev/null; then
    echo "❌ 基线 $base 不存在(在 feature worktree 里跑,或在主检出显式传 base)" >&2
    exit 2
  fi
  changed_prod=$(git diff --name-only "$base"...HEAD -- 'NemoNotch/*.swift' 2>/dev/null || true)
  changed_tests=$(git diff --name-only "$base"...HEAD -- 'NemoNotchTests/*.swift' 2>/dev/null || true)
fi

if [ -z "$changed_prod" ] && [ -z "$changed_tests" ]; then
  echo "affected: 无 Swift 改动 — 无需跑测试"
  exit 0
fi

# 符号抽取分两级:类型符号(class/struct/enum/protocol/extension/actor/typealias)
# 是稳定的公共面,命中即够;函数名(start/stop/parse 这类常见词)会把半个测试
# 目录误吸进来,只在**该文件没有任何类型**时才降级使用(堵纯函数文件漏测)。
# 重复修饰符前缀逐个消化;属性另起一行的声明靠关键字行命中。
extract() {  # extract <decl-keywords-regex> <file> — 只认列 0 的顶层声明:
  # 嵌套类型必缩进(private struct Window / enum Mode 这类短名只会误吸),
  # 测试够得着的外部面本来就只有顶层。
  sed -n -E "s/^((final |public |internal |open |@[A-Za-z]+ )*)($1) ([A-Za-z_][A-Za-z0-9_]*)[ ({<:.].*/\4/p" "$2"
}
types_re="class|struct|enum|protocol|extension|actor|typealias"
funcs_re="class|struct|enum|protocol|extension|actor|typealias|func"
symbols=$(for f in $changed_prod; do
  [ -f "$f" ] || continue
  t=$(extract "$types_re" "$f")
  if [ -n "$t" ]; then echo "$t"; else extract "$funcs_re" "$f"; fi
done | sort -u)
# 仓库声明集过滤:extension View/String 这类**框架类型**的扩展抽出的符号名
# 会 grep 命中半个测试目录;只保留在 NemoNotch/ 内真正声明过的类型名。
# (交集用 grep -Fx -f + 临时文件 —— 本机 /bin/sh 不支持 <() 进程替换,踩过。)
declared_tmp=$(mktemp /tmp/affected-declared.XXXXXX)
grep -rh -E "^((final |public |private |fileprivate |internal |open |static |@[A-Za-z]+ )*)(class|struct|enum|protocol|actor|typealias) [A-Za-z_][A-Za-z0-9_]*" NemoNotch --include='*.swift' 2>/dev/null | sed -E 's/^((final |public |private |fileprivate |internal |open |static |@[A-Za-z]+ )*)(class|struct|enum|protocol|actor|typealias) ([A-Za-z_][A-Za-z0-9_]*).*/\4/' | sort -u > "$declared_tmp"
symbols=$(printf '%s\n' "$symbols" | grep -Fx -f "$declared_tmp" || true)
rm -f "$declared_tmp"

# 引用了任一符号的测试文件 + 改动的测试文件自身 → 类名(文件名)
classes=""
if [ -n "$symbols" ]; then
  pattern=$(echo "$symbols" | paste -sd'|' -)
  for t in $(grep -l -E "$pattern" NemoNotchTests/*.swift 2>/dev/null || true); do
    classes="$classes $(basename "$t" .swift)"
  done
fi
for t in $changed_tests; do
  [ -f "$t" ] && classes="$classes $(basename "$t" .swift)"
done
classes=$(echo $classes | tr ' ' '\n' | sort -u | sed '/^$/d' | paste -sd, -)

echo "affected: 改动 $(echo "$changed_prod $changed_tests" | wc -w | tr -d ' ') 个 Swift 文件,命中符号 $(echo "$symbols" | grep -c .) 个"
if [ -z "$classes" ]; then
  echo "affected: 映射为空 → 回落全量(确定性优先,宁多跑不漏跑)"
  exec sh scripts/test.sh
fi
echo "affected: 选出测试类: $classes"
exec sh scripts/test.sh --only "$classes"
