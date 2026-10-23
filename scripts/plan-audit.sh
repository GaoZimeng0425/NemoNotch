#!/bin/sh
# plan-audit.sh — plan 全勾门禁:feature 分支动过的 plan 文档不许有裸着的未勾任务框。
#
# 「收尾全勾」的机械化(octok-client 工作流借鉴,2026-10-23):doc-audit 只对账固定
# 的成对断言,「实现者漏做半张 plan 也能合」是它的盲区。判据纯文本、零人工:全勾
# 直过;有裸框则非零退出、列 file:行号——这时才需要人决定补做还是记跳过原因。
# 跳过某任务的合法形态:勾上 `- [x]` 并在行尾写原因,或删掉该行;框不许裸着。
# 在 feature worktree 根目录跑;范围只限 docs/superpowers/plans/,排除 archive/
# (历史归档不重新审判——「ship 后 plan 挪 archive/」是常规动作,搬运旧 plan 不许踩门禁)。
set -u

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "❌ plan-audit 要在 git 仓库里跑" >&2
  exit 2
fi

# 与 feat-done 同判据:merge-base(develop, HEAD) = 本分支自己的改动。
# develop 缺失时退 HEAD~1 并报出所用 base——宁可少判也不静默换语义;
# merge-base 本身失败则按失败停(fail-closed:判不了改动面 ≠ 没有改动)。
if git rev-parse --verify --quiet develop >/dev/null 2>&1; then
  base=$(git merge-base HEAD develop) || {
    echo "❌ git merge-base 失败 — 判不了「本分支的改动」,按失败停" >&2
    exit 2
  }
else
  base=$(git rev-parse HEAD~1)
  echo "⚠️  无 develop 分支,按 HEAD~1($base)判 — 预期在 feature worktree 里跑" >&2
fi

# --no-renames:改名拆成 删+增,增侧照进审计;--diff-filter=AM 只看新增/修改;
# :(exclude) 排除 archive/(见文件头注释)。
plans=$(git diff --name-only --no-renames --diff-filter=AM "$base...HEAD" -- 'docs/superpowers/plans/' ':(exclude)docs/superpowers/plans/archive/')
if [ -z "$plans" ]; then
  echo "✅ plan 全勾门禁:本分支未动 plan 文档 — 跳过"
  exit 0
fi

violations=''
# IFS 换行:文件名带空格也不拆
IFS='
'
for f in $plans; do
  if [ ! -f "$f" ]; then
    # diff 报了它但工作区没有(比如从子目录跑)——按违例停而不是静默跳过(假绿方向零容忍)
    violations="$violations$f: diff 报有此文件但工作区找不到 — 在 worktree 根目录跑 plan-audit
"
    continue
  fi
  git diff --quiet HEAD -- "$f" || echo "⚠️  $f 有未提交改动 — 门禁审计的是工作区版,合并只带走已提交版" >&2
  hits=$(grep -n '^[[:space:]]*[-*] \[ \]' "$f" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    violations="$violations$f:
$hits
"
  fi
done

if [ -n "$violations" ]; then
  echo "❌ plan 全勾门禁未过 — 以下任务框未勾(补做,或勾上写跳过原因,或删行;框不许裸着):" >&2
  printf '%s' "$violations" >&2
  exit 1
fi

echo "✅ plan 全勾门禁:本分支动过的 plan 文档任务全勾"
exit 0
