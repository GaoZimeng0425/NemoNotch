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
#   sh scripts/review.sh <name>                      # 生成/刷新 .reviews/<name>.md 模板
#   sh scripts/review.sh <name> --prompt             # 打印评审派发 prompt(不写任何文件)
#   sh scripts/review.sh <name> --prompt --prev <h>  # 增量复审 prompt:只核 <h>..HEAD
#   评审者填完 Findings 与 Verdict 后:  git add .reviews/<name>.md
#
# --prompt(2026-11-02,工具中立):评审派发的 prompt 由本脚本定形,ZCode / Claude Code
# 各自把它粘给自己的子代理工具——铁律(零 git 状态变更、不改文件)和 bug 专项镜头写死
# 在模板里,不再每次手搓(手搓漏一条铁律 = 子代理裸 git pull 重写 develop 的实案)。
set -u

name="${1:-}"
if [ -z "$name" ]; then
  echo "usage: sh scripts/review.sh <feature-name> [--prompt [--prev <head>]]" >&2
  exit 2
fi
shift
prompt_mode=0
prev=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) prompt_mode=1 ;;
    --prev)
      shift
      prev="${1:-}"
      if [ -z "$prev" ]; then
        echo "✋ --prev 需要上轮 Reviewed-Head 短哈希" >&2
        exit 2
      fi
      ;;
    *) echo "✋ 未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

# 评审派发 prompt(工具中立)。变量在调用时求值:wt / base / name / prev。
emit_prompt() {
  if [ -n "$prev" ]; then
    range="$prev..HEAD"
    mode_block="## 增量复审模式
上轮评审 Reviewed-Head 为 \`$prev\`。只核修复提交:\`git diff $prev..HEAD\`。先做零代码漂移检查
\`git diff $prev..HEAD -- . ':!.reviews'\`(空 = 只动了评审记录,维持上轮 Verdict 即可)。
Findings 只针对 $prev 之后的改动;更新记录的 Reviewed-Head 为当前 head,维持或改判 Verdict。"
  else
    range="$base...HEAD"
    mode_block="## 首轮评审
全量改动:\`git diff $range\`;重要文件直接读上下文,别只看 diff 片段。"
  fi
  cat <<EOF
你是独立评审员(judge ≠ author):你没有参与 feature/$name 的开发,也看不到作者的对话。

Worktree(只读;在此执行命令):$wt
分支:feature/$name    评审范围:$range

## 事实(由派发方填写;只给症状/需求事实,不给实现思路)
<<填:症状/需求事实,不含实现思路>>

$mode_block

## 步骤
1. 先跑 \`sh scripts/review.sh $name\` 拿审查清单(.reviews/$name.md 模板),逐项过;仓库规矩读 worktree 里的 AGENTS.md。
2. 验证必须亲跑并引用真实退出码:\`sh scripts/lint.sh\`、\`sh scripts/doc-audit.sh\`、\`sh scripts/check-arch.sh\`;有 Swift 改动再跑 \`sh scripts/affected-tests.sh\`(有新守卫/新测试则用 \`sh scripts/mutate.sh\` 验证有牙)。不信作者自述。
3. bug 专项镜头(修 bug 的分支必查):①失败测试红→绿可重放(测试提交早于修复提交,被测函数在测试提交时仍是旧实现);②修复与根因因果对应,不是绕开症状;③推翻的旧口径全仓 grep 清场(AGENTS.md、docs/、注释)。
4. 把 .reviews/$name.md **填完整后全文返回**(不要只返回摘要),字段行保持行首裸格式:
   - \`Reviewer:\` 你的标识
   - \`Reviewed-Head:\` \`git rev-parse --short HEAD\` 的输出
   - \`Verdict: APPROVED\`(或 \`Verdict: CHANGES_NEEDED\` / \`Verdict: 无法验证\`)——APPROVED 意味着「我愿意为这个合并背书」
   - Findings 按 P1/P2/P3,每条带 file:line 与一句话修法;尾部「教训候选」小节(没有写"无")

## 铁律
- **零 git 状态变更**:不 pull、不 push、不 merge、不 rebase、不 checkout、不 commit、不 stash(本仓 branch.develop.rebase=true,裸 git pull 会重写 develop——2026-11-02 实案)。
- **不改任何文件**(包括 .reviews/):记录全文返回,由派发方原样落盘并提交。
- **不跑 build.sh**(它会部署并重启 app)。
- 无法验证就明说,不猜。中文回复,技术名保留。
EOF
}

main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
branch="feature/$name"

if ! git -C "$main_wt" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "✋ 找不到分支 ${branch}。" >&2
  exit 1
fi
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2} /^branch /{ if ($2==b) print p }')
if [ -z "$wt" ]; then
  echo "✋ 分支 $branch 没有 worktree(已删?)——评审记录手动建在 .reviews/$name.md 并随分支提交。" >&2
  exit 1
fi

base=$(git -C "$main_wt" merge-base develop "$branch")

# --prompt 只打印、不碰 .reviews/(模板生成与「已填 Verdict 不覆盖」逻辑全在其后,原样不动)
if [ "$prompt_mode" = 1 ]; then
  emit_prompt
  exit 0
fi

note="$wt/.reviews/$name.md"
mkdir -p "$wt/.reviews"

# 已填 Verdict 的记录(APPROVED / CHANGES_NEEDED / 无法验证)都是证据,不覆盖——自动
# 重生成只许作用于空白模板(feat-done 门禁会代跑本脚本;曾把填好的 CHANGES_NEEDED
# 洗回空白模板,评审实测)。要重评先人工清掉 Verdict 行。
# 只认**已填值**:模板自带的占位行 `Verdict: (填 …)` 也以 `Verdict:` 开头,裸 `^Verdict:`
# 会把刚生成的空白模板误判成「已填」,重跑时报「不覆盖」而其实什么都没填(评审员 2026-11-02 实遇)。
if [ -f "$note" ] && grep -Eq '^Verdict: *(APPROVED|CHANGES_NEEDED|无法验证)' "$note"; then
  echo "✅ .reviews/$name.md 已有已填 Verdict 的记录 — 不覆盖。要重评先人工清掉 Verdict 行。"
  exit 0
fi

stat=$(git -C "$wt" diff --stat "$base...HEAD" | tail -1)
files=$(git -C "$wt" diff --name-only "$base...HEAD")

# 工作流机制清场项(条件生成):触及 hooks/scripts/CI 的 feature 自动多一行清单——
# 触发集与 feat-done 评审门禁的工程面同判据。判断(哪个旧口径死了、grep 哪个词)
# 留给评审者;脚本只保证「这一步不被遗忘」(octok「机制改动必带全文档 sweep」的
# 借鉴,2026-10-23)。
mech=$(printf '%s\n' "$files" | grep -E '^(\.githooks/|scripts/|\.github/)' || true)
mech_item=""
if [ -n "$mech" ]; then
  mech_item='- [ ] **工作流机制清场**:本分支触及 hooks/scripts/CI——旧口径(措辞/路径/次序)全仓 grep 过了吗(AGENTS.md、docs/、注释)?证据贴 Findings。'
fi

cat > "$note" <<EOF
# Code Review — feature/$name

Reviewer: (填:评审会话/子代理标识。绝不能是写这段代码的那个——judge ≠ author)
Date: $(date +%F)
Reviewed-Head: (填:评审时分支 head 短哈希,git rev-parse --short HEAD。feat-done 会核对它与最近一次非 .reviews 提交的 head 一致——rebase/重写后旧 Verdict 失效,须补审)
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
- [ ] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [ ] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?
${mech_item}
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
