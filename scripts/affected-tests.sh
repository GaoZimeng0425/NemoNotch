#!/bin/sh
# affected-tests.sh — 确定性影响面测试选择(「能硬化的都硬化」)。
# 两级选择器(2026-11-03):
#   一级(优先)编译器索引闭包:scripts/index-affected.swift(libIndexStore,
#     读本 worktree DerivedData 的 Index.noindex/DataStore)对改动文件求传递
#     引用闭包(a 引 b、b 引 c → c b a 全选),闭包 ∩ NemoNotchTests/*Tests.swift
#     → 类名(文件名即类名的约定不变,只对 *Tests.swift 认)。
#   二级(回落)文本符号匹配(原实现整段保留):无索引/新文件未构建/dylib 缺失/
#     CLI 异常时兜底;fresh worktree 未构建过天然走二级。
# 共同出口:类列表 → test.sh --only;映射为空 → 全量(宁多跑不漏跑;健康闭包
#   为空也全量——v1 不信空)。旧索引/同名误吸只会多选,方向安全。
# 新鲜度:索引 = 最近一次构建的快照;「改完未构建就跑」窗口内按旧图选(旧名
#   引用者仍被选出,偏安全),随后的 xcodebuild 会顺带刷新索引。
# 原二级的背景:--only 类名曾由 agent 挑选出过选错类假绿;ripwire --affected 对
# Swift Testing 宏测试解析不了(tests=0 实测),故自建确定性映射,零判断:
#   改动的生产 .swift → 顶层符号 → 引用任一符号的测试文件 + 改动的测试文件自身
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

# ── 一级:编译器索引闭包(libIndexStore)─────────────────────────────
# 定位:info.plist 的 WorkspacePath 与 $root/NemoNotch.xcodeproj 绝对路径全等
# (本机常驻多个 NemoNotch-<hash> DerivedData,已合并 worktree 的化石目录不许误匹配)。
# 失败语义:任何不健康(无索引/swift 缺失/CLI 非零)→ 走二级文本回落;
# 健康且闭包∩测试为空 → 全量(v1 不信空)。原因经 stderr 回传(函数在子壳里跑)。
locate_datastore() {
  proj="$root/NemoNotch.xcodeproj"
  for d in "$HOME/Library/Developer/Xcode/DerivedData"/NemoNotch-*/; do
    [ -f "$d/info.plist" ] || continue
    if [ "$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null)" = "$proj" ] \
       && [ -d "$d/Index.noindex/DataStore" ]; then
      echo "$d/Index.noindex/DataStore"
      return 0
    fi
  done
  return 1
}

index_closure_classes() {  # stdout: 逗号类名(可为空);exit 0 = 索引健康
  ds=$(locate_datastore) || { echo "无本 worktree 的 DerivedData 索引(未构建过?)" >&2; return 1; }
  command -v swift >/dev/null 2>&1 || { echo "swift 不在 PATH" >&2; return 1; }
  # shellcheck disable=SC2086
  closure_out=$(swift "$root/scripts/index-affected.swift" closure "$ds" "$root" $changed_prod 2>/dev/null) \
    || { echo "CLI exit 非零(索引不健康/新文件未构建/dylib 缺失)" >&2; return 1; }
  cls=""
  for f in $closure_out; do
    case "$f" in
      NemoNotchTests/*Tests.swift) cls="$cls $(basename "$f" .swift)" ;;
    esac
  done
  echo "闭包 $(printf '%s\n' "$closure_out" | grep -c .) 文件,命中测试 $(echo $cls | wc -w | tr -d ' ') 类" >&2
  echo $cls | tr ' ' '\n' | sed '/^$/d' | paste -sd, -
}

if [ -n "$changed_prod" ]; then
  reason_file=$(mktemp /tmp/affected-reason.XXXXXX)
  if classes=$(index_closure_classes 2>"$reason_file"); then
    note=$(cat "$reason_file")
    rm -f "$reason_file"
    # shellcheck disable=SC2086
    for t in $changed_tests; do
      [ -f "$t" ] && classes="$classes,$(basename "$t" .swift)"
    done
    classes=$(echo "$classes" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -)
    echo "affected: 改动 $(echo $changed_prod $changed_tests | wc -w | tr -d ' ') 个 Swift 文件;选择器=索引闭包($note)"
    if [ -z "$classes" ]; then
      echo "affected: 闭包与测试交集为空 → 回落全量(v1 不信空,宁多跑不漏跑)"
      exec sh scripts/test.sh
    fi
    echo "affected: 选出测试类: $classes"
    exec sh scripts/test.sh --only "$classes"
  fi
  echo "affected: 选择器=文本回落($(cat "$reason_file"; rm -f "$reason_file"))"
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
