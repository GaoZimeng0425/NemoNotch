#!/bin/sh
# review.sh <feature-name> — 组装评审输入 + 生成评审记录模板(.reviews/<name>.md)。
# 「评审 ≠ 作者」的机械化一半:判断仍是人/子代理的,但评审的输入(改了什么)与
# 输出(带 Verdict 的记录)由脚本定形,feat-done 检查记录存在且 Verdict: APPROVED
# 才放行合并(2026-10-20 落地)。
#
# 评审者身份要求:绝不能是写这段代码的会话/子代理——新开一个会话(或 spawn
# 一个 fresh 的 code-review 子代理)来读 diff、填记录。评审记录随 feature 分支
# 提交,成为永久证据链(.superpowers/sdd/ 的延续)。
#
# Usage:
#   sh scripts/review.sh <name>          # 生成/刷新 .reviews/<name>.md 模板
#   评审者填完 Findings 与 Verdict 后:  git add .reviews/<name>.md
set -u

name="$1"
if [ -z "$name" ]; then
  echo "usage: sh scripts/review.sh <feature-name>" >&2
  exit 2
fi

main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
branch="feature/$name"

if ! git -C "$main_wt" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "✋ 找不到分支 $branch。" >&2
  exit 1
fi
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2} /^branch /{ if ($2==b) print p }')
if [ -z "$wt" ]; then
  echo "✋ 分支 $branch 没有 worktree(已删?)——评审记录手动建在 .reviews/$name.md 并随分支提交。" >&2
  exit 1
fi

base=$(git -C "$main_wt" merge-base develop "$branch")
note="$wt/.reviews/$name.md"
mkdir -p "$wt/.reviews"

# 已有填好的记录时不覆盖(评审是证据,不是模板)
if [ -f "$note" ] && grep -q '^Verdict: APPROVED' "$note"; then
  echo "✅ .reviews/$name.md 已有 APPROVED 记录 — 不覆盖。要重评先人工清掉 Verdict 行。"
  exit 0
fi

stat=$(git -C "$wt" diff --stat "$base...HEAD" | tail -1)
files=$(git -C "$wt" diff --name-only "$base...HEAD")

cat > "$note" <<EOF
# Code Review — feature/$name

Reviewer: (填:评审会话/子代理标识。绝不能是写这段代码的那个——judge ≠ author)
Date: $(date +%F)
Verdict: (填 APPROVED 或 CHANGES_NEEDED —— feat-done 门禁按行首「Verdict: APPROVED」匹配,保持行首裸格式)
Scope: ${stat:-无改动}

\`\`\`
${files:-(无文件)}
\`\`\`

## Findings

- (逐条:位置 file:line、问题一句话、严重度 [P1/P2/P3];没有就写"无")

## 审查清单(评审者逐项过,不适用项标 N/A)

- [ ] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [ ] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [ ] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [ ] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [ ] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [ ] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [ ] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:\`git diff $base...HEAD\` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
EOF

echo "📝 评审记录模板已生成: $note"
echo "   下一步:让**未参与开发的**会话/子代理评审,填 Findings 与 Verdict 后提交:"
echo "     cd \"$wt\" && git diff $base...HEAD   # 评审者看改动"
echo "     git add .reviews/$name.md            # 评审者填完记录后"
echo "   feat-done 会在合并前检查 Verdict: APPROVED(纯文档 feature 自动跳过)。"
