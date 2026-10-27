#!/bin/sh
# NemoNotch 架构围栏 — 坑总目录里「机器可判定」的不变量,从散文变成秒级门禁。
#
# 起因(2026-10-27,octok-platform 调研):他们的 30+ 个 check-* 脚本把架构不变量
# 做成可执行检查,每条规则的头部注释写明「哪次事故催生的、为什么类型系统和
# 单测看不见它」。我们对照的缺口:AGENTS.md 坑总目录的「绝不许」全是散文,
# 靠评审员每次记得对照 — 忘了就漏。本脚本把其中可用文本/语法模式判定的部分
# 接进 feat-done 与 CI,触犯的改动在合并前被拦下。
#
# 两档语义:
#   A 档(全仓):模式在 NemoNotch/ 任何非注释行命中即拦。校准要求:上线时
#     零命中(或已知的合法位点带行内豁免)。没有 baseline 账本 — 哪条规则
#     校准不到零又改不准形状,它就不上线(宁缺毋滥:会假红的警报会被学会忽略)。
#   B 档(只拦新增):模式只在本分支 diff 的新增行命中才拦。用于「现存有合法
#     使用、但不想再新增」的模式;新增需在行尾注释 `// fence: allow` 显式豁免
#     (豁免写在代码里,评审看得见 — octok `tx-check: ignore` 同款哲学)。
#
# 通用过滤:注释行(行首空白后以 // 开头)跳过;含 `fence: allow` 的行跳过。
#
# Usage:
#   sh scripts/check-arch.sh             # 门禁模式:A 档全仓 + B 档本分支新增行;命中 exit 1
#   sh scripts/check-arch.sh --all       # 全仓体检:A 档全量(拦语义)+ B 档全仓仅列举(信息性,不影响退出码)
#   sh scripts/check-arch.sh --selftest  # 每条规则喂「应命中/不应命中」样本,验证模式本身没腐化
# CI:.github/workflows/doc-audit.yml(与 doc-audit 同 job,纯 grep,ubuntu)。
# feat-done:.githooks/feat-done.sh 在 plan-audit 之后调用;逃生阀 NEMONOTCH_SKIP_ARCH=1。
#
# 加新规则的三条规矩(照抄 octok CHECK_RULES 哲学 — 规则与「为什么」同住):
#   1. 每条规则上方注释写清:拦什么、为什么(指向 AGENTS.md 具体条目)、校准现状;
#   2. A 档必须校准到零命中(或合法位点带豁免注释);做不到就进 B 档或不上线;
#   3. 出生必须 --selftest 全绿 + 门禁模式对合成违规见红一次(样本要有鉴别力:
#      「不应命中」样本得是真实容易误写的形状,不是摆设)。
#
# 已知局限(诚实边界,评审时别当漏抓来报):
#   - 行尾注释里提到模式词(如 `foo() // 见 ScriptingBridge`)仍会误报 — 行级
#     注释过滤只认行首注释;
#   - 无类型信息:NSWindow.close() 禁令(换窗只许 orderOut)因此刻意不做 —
#     实测 13 处 .close() 全是 FileHandle 的,grep/ast-grep 都切不准,留给
#     review.sh 的坑总目录对照项;
#   - 字面 `?` 写成 `[?]`、不用 `\b`(BSD/GNU grep 词边界语义不稳)— 全部
#     模式必须 POSIX ERE,macOS 与 ubuntu 同时可跑。
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
SRC="NemoNotch"

# ── 通用件 ─────────────────────────────────────────────────────────────

# stdin: grep -n/-rn 的输出(path:line:content 或 line:content)
# 滤掉注释行与豁免行。两段 grep 任一段无输出都算「无命中」,不算错误。
filter_hits() {
  # 冒号数兼容:grep -n 是「line:content」,grep -rn 是「path:line:content」
  { grep -vE '^[^:]*:([0-9]+:)?[[:space:]]*//' || true; } | { grep -v 'fence: allow' || true; }
}

# 在指定目录集里找模式命中(A 档执行件)。$1=ERE,其余=目录。
scan_dirs() {
  pat=$1; shift
  grep -rnE --include='*.swift' -- "$pat" "$@" 2>/dev/null | filter_hits
}

# B 档执行件:stdin 吃 `git diff -U0` 文本,打印「新增行中命中模式的 file:line:content」。
# awk 按 +++ 头与 @@ 头跟踪 file:line;行首注释与豁免行在此滤。
# ⚠️ 模式经 ENVIRON 传入,**绝不用 `-v`**:POSIX 规定 `-v` 对值做反斜杠转义,
# `\.opacity\(` 会被剥成 `.opacity(` → awk 动态正则语法错、exit 2、零输出 →
# 命令替换吞掉退出码 → 假绿放行(评审 F1 实锤:坏在 CPU 22% 那条规则上,
# 出生仪式没抓到是因为只拿无反斜杠的 repeatForever 测过 B 档)。
# 配套:调用侧对执行器退出码做 fail-closed 守卫(见 run_b_tier),崩溃≠无命中。
added_line_hits() {
  FENCE_PAT=$1 awk '
    /^\+\+\+ / { file=$2; sub(/^b\//, "", file); next }
    /^@@ /     { for (i = 1; i <= NF; i++) if ($i ~ /^\+[0-9]/) { split(substr($i, 2), a, ","); ln = a[1] - 1 } next }
    /^\+/      { ln++; line = substr($0, 2)
                  if (line !~ /^[[:space:]]*\/\// && line !~ /fence: allow/ && line ~ ENVIRON["FENCE_PAT"])
                    print file ":" ln ":" line }
  '
}

violations=0

# 模式合法性预检(F3 同族):坏正则(加规则时手滑)在 grep/awk 都是「exit 2 + 零输出」,
# 不预检就会一路假绿。任何模式编不过 → 响亮失败。
validate_patterns() {
  for p in "$PAT_SB" "$PAT_OPACITY_HIDE" "$PAT_RUSAGE" "$PAT_UI_DICT" 'repeatForever'; do
    if ! printf 'probe\n' | grep -qE -- "$p" 2>/dev/null; then
      echo "❌ [arch] 模式非法(加规则时写坏了?):$p" >&2
      exit 1
    fi
  done
}

# $1=规则id $2=why(含 AGENTS.md 指针) $3=findings 串(换行分隔;空=通过)
report_block() {
  [ -n "$3" ] || return 0
  violations=$((violations + 1))
  echo "❌ [arch:$1] $2" >&2
  printf '%s\n' "$3" | sed 's/^/     /' >&2
}

# ── A 档规则表(与「为什么」同住)──────────────────────────────────────

# scriptingbridge — 媒体控制只许走 mediaremote-adapter perl 桥。
# macOS 15.4 起 MediaRemote 私有控制函数锁给 Apple 签名进程,进程内调用静默
# no-op;ScriptingBridge/Automation 路线已死,复活它 = 控制按钮静默失灵。
# → AGENTS.md「媒体」节。校准(2026-10-27):0 命中。
PAT_SB='ScriptingBridge|SBApplication'

# opacity-hide(B 档)— 条件 opacity 隐藏子树(分支值精确到 0)。
# opacity(0) 不卸载视图:整个子树活着并持续干活,曾致收起态整机 CPU 22%
# (cpu_resource 看门狗实案);隐藏昂贵子树必须门控挂载 + .transition。
# 模式只认「三元某分支精确为 0」(0 后必须非数字非小数点 — `? 0.68 : 1`
# 这类变暗三元从不隐藏视图,合法;`\.black.opacity(0.3), x: 0` 这类无三元
# 的行也不在射程)。frame(width/height: 0) 同罪。
# 字面 .opacity(0) 是合法渐变端点(Color.opacity(0)),无类型信息切不开,
# 故不在射程。→ AGENTS.md「坑总目录·SwiftUI 渲染与动画」。
# 校准(2026-10-27):**降 B 档** — 实测全仓 8 处存量使用(胶囊淡入淡出/
# 边栏可见性/徽章显隐/Notch 内容),逐处判断「是否昂贵子树」超出本围栏
# 成熟度;只拦新增,新增需门控挂载或行内豁免。
PAT_OPACITY_HIDE='\.opacity\(.*[?][[:space:]]*0([^[:alnum:].]|$)|\.opacity\(.*[?][^)]*:[[:space:]]*0([^[:alnum:].]|$)|\.frame\((width|height):[[:space:]]*0\)'

# proc-pid-rusage — PerfProbe 只许 getrusage。
# 当前 SDK 的 rusage_info_current 结构版本与内核写回不一致,proc_pid_rusage
# 调用直接 SIGABRT(实测)。→ AGENTS.md「工具与探针」。
# 校准(2026-10-27):0 命中(仅 PerfProbe 注释提及,注释行已滤)。
PAT_RUSAGE='proc_pid_rusage\('

# ui-store-dict — UI 只读 sortedSessions,不直读 store 原始会话字典。
# AISessionStore 是唯一会话真相源;UI 直读 sessions 字典绕过缓存排序与
# phaseChangedAt 语义。射程仅 UI 目录(Tabs/Notch/Settings);`.sessions(`
# 形(sessions(for:) API)与 .sortedSessions 不在射程(后缀字符类排除)。
# → AGENTS.md「架构不变量」。校准(2026-10-27):0 命中。
PAT_UI_DICT='\.sessions([^[:alnum:]_(]|$)'

run_a_tier() {
  report_block scriptingbridge \
    "ScriptingBridge 已死 — 媒体控制只走 MediaRemoteCommander perl 桥 → AGENTS.md「媒体」" \
    "$(scan_dirs "$PAT_SB" "$SRC")"

  report_block proc-pid-rusage \
    "proc-pid-rusage 在当前 SDK 直接 SIGABRT — 只许 getrusage → AGENTS.md「工具与探针」" \
    "$(scan_dirs "$PAT_RUSAGE" "$SRC")"

  report_block ui-store-dict \
    "UI 直读 store.sessions 原始字典 — 只许 sortedSessions / sessions(for:) → AGENTS.md「架构不变量」" \
    "$(scan_dirs "$PAT_UI_DICT" "$SRC/Tabs" "$SRC/Notch" "$SRC/Settings")"

  # keychain-returndata — kSecReturnData 只许出现在既有的两个凭据模块。
  # GUI app 的 kSecReturnData 读永远弹跨 app ACL 对话;存在性探测必须
  # attributes-only,交互读只在 authorize 路径。文件级允许清单,清单外
  # 出现即拦。→ AGENTS.md「Keychain/权限/TCC」。
  # 校准(2026-10-27):现存命中恰好全在清单内。
  _kc=
  for f in $(grep -rlE --include='*.swift' -- 'kSecReturnData' "$SRC" 2>/dev/null || true); do
    keychain_allowed "$f" || _kc="$_kc$f — kSecReturnData 出现在允许清单外
"
  done
  report_block keychain-returndata \
    "kSecReturnData 只许在 {Services/UsageQuotaService+Keychain.swift, Services/UsageQuotaService+Codex.swift} — 别处出现 = 新增交互读路径 → AGENTS.md「Keychain/权限/TCC」" \
    "$_kc"
}

KEYCHAIN_RETURNDATA_ALLOWLIST="Services/UsageQuotaService+Keychain.swift Services/UsageQuotaService+Codex.swift"
keychain_allowed() { # $1 = 仓库根起的相对路径
  for a in $KEYCHAIN_RETURNDATA_ALLOWLIST; do
    [ "$1" = "$SRC/$a" ] && return 0
  done
  return 1
}

# ── B 档规则表(只拦本分支新增行)──────────────────────────────────────

# repeat-forever(B 档)— 不再新增 repeatForever 动画。
# 它停不掉(赋新值仍在跑)、隐藏当前插值、在布局会变的元素上出鬼影帧 —
# 三条坑全在 AGENTS.md;持续动作用 TimelineView(.animation(paused:)) 或
# CABasicAnimation。现存 4 处真实使用(脉冲/跑马灯,位置已知)不追,只拦新增;
# 确需新增:行尾 // fence: allow + 评审说明。→ AGENTS.md「坑总目录」。

b_tier_diff() { # 打印本分支 diff 的 -U0 文本(相对 merge-base develop)
  base=$(git merge-base HEAD develop 2>/dev/null) || return 1
  git diff -U0 "$base" HEAD -- '*.swift'
}

WHY_B_OPACITY='条件 opacity/frame(0) 隐藏子树 = 子树不卸载(CPU 22% 实案)→ AGENTS.md「坑总目录」;隐藏要门控挂载,瞬时过渡态行尾 // fence: allow'
WHY_B_REPEAT='新增 repeatForever — 停不掉/鬼影帧(TimelineView 或 CABasicAnimation 替代)→ AGENTS.md「坑总目录」;确需:行尾 // fence: allow'

run_b_tier() { # 门禁模式:新增行命中即拦(两条规则,显式展开 — 比 while 管道子壳直白)
  if ! b_tier_diff >/dev/null 2>&1; then
    echo "⚠️  [arch] B 档跳过:merge-base HEAD develop 不可得(develop 缺失?)— A 档仍全量拦截" >&2
    return 0
  fi
  # F3 守卫:执行器崩溃(awk/grep 非零退出)绝不降级成「无命中」——一次假绿 =
  # 放行一个错误,比没有这道门更糟。命令替换的退出码 = 管道末命令的退出码。
  _h_op=$(b_tier_diff | added_line_hits "$PAT_OPACITY_HIDE") || {
    echo "❌ [arch] B 档执行器出错(opacity-hide)— 按失败处理,不放行" >&2; exit 1; }
  _h_rf=$(b_tier_diff | added_line_hits 'repeatForever') || {
    echo "❌ [arch] B 档执行器出错(repeatForever)— 按失败处理,不放行" >&2; exit 1; }
  report_block "b:opacity-hide" "$WHY_B_OPACITY" "$_h_op"
  report_block "b:repeatForever" "$WHY_B_REPEAT" "$_h_rf"
}

list_b_tier_repo() { # --all 用:全仓现存使用,信息性列举(不影响退出码)
  report_list "opacity-hide" "$(scan_dirs "$PAT_OPACITY_HIDE" "$SRC")"
  report_list "repeatForever" "$(scan_dirs 'repeatForever' "$SRC")"
}

report_list() { # $1=规则名 $2=命中串 — 只列举不拦
  [ -n "$2" ] || return 0
  echo "ℹ️  [b:$1] 全仓现存使用(信息性,不拦;门禁只拦新增行):"
  printf '%s\n' "$2" | sed 's/^/     /'
}

# ── 模式 ───────────────────────────────────────────────────────────────

case "${1:-}" in
--selftest)
  # 每条样本都要有鉴别力:「不应命中」必须是真实容易误写的形状
  #(变暗三元/渐变端点/sessions(for:) 均取自本仓真实代码)。
  fails=0
  t() { # t <名称> <hit|miss> <模式> <样本行>
    _res=$(printf '%s\n' "$4" | grep -nE -- "$3" | filter_hits)
    _got=miss; [ -n "$_res" ] && _got=hit
    if [ "$_got" != "$2" ]; then
      echo "❌ selftest: $1 — 期望 $2 实得 ${_got} (模式:$3 / 样本:$4)" >&2
      fails=$((fails + 1))
    fi
  }
  t "sb 调用命中"          hit  "$PAT_SB" 'let app = SBApplication(bundleIdentifier: id)'
  t "sb 注释不命中"        miss "$PAT_SB" '        // SBApplication 路线已死'
  t "条件隐藏(then 0)命中"  hit  "$PAT_OPACITY_HIDE" '.opacity(hidden ? 0 : 1)'
  t "条件隐藏(else 0)命中"  hit  "$PAT_OPACITY_HIDE" '.opacity(hidden ? 1 : 0)'
  t "frame0 命中"          hit  "$PAT_OPACITY_HIDE" '.frame(width: 0)'
  t "变暗三元(0.68)不命中" miss "$PAT_OPACITY_HIDE" '.opacity(task.isDone ? 0.68 : 1)'
  t "变暗三元(0.5)不命中"  miss "$PAT_OPACITY_HIDE" '.opacity(event.isPast ? 0.5 : 1)'
  t "悬停透明度不命中"      miss "$PAT_OPACITY_HIDE" '.fill(Color.white.opacity(hovered ? 0.16 : 0.11))'
  t "阴影参数x:0不命中"     miss "$PAT_OPACITY_HIDE" '.shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)'
  t "渐变端点不命中"        miss "$PAT_OPACITY_HIDE" 'colors: [.pink.opacity(0), .pink]'
  t "过渡态带豁免不命中"    miss "$PAT_OPACITY_HIDE" '.opacity(active ? 0 : 1) // fence: allow — 入场过渡瞬时态'
  t "rusage 调用命中"       hit  "$PAT_RUSAGE" 'foo(proc_pid_rusage(pid, 0, rbuf))'
  t "rusage 注释不命中"     miss "$PAT_RUSAGE" '  /// proc_pid_rusage 在当前 SDK 会 SIGABRT'
  t "直读字典命中"          hit  "$PAT_UI_DICT" 'let s = store.sessions[id]'
  t "sortedSessions 不命中" miss "$PAT_UI_DICT" 'let s = store.sortedSessions'
  t "sessions(for:) 不命中" miss "$PAT_UI_DICT" 'let s = store.sessions(for: .claude)'
  # keychain 允许清单逻辑直接测函数
  if keychain_allowed "NemoNotch/Services/UsageQuotaService+Keychain.swift"; then :; else
    echo "❌ selftest: keychain 允许清单内文件应放行" >&2; fails=$((fails + 1)); fi
  if keychain_allowed "NemoNotch/Services/NewThing.swift"; then
    echo "❌ selftest: keychain 清单外文件应拦下" >&2; fails=$((fails + 1)); fi
  # B 档:合成 diff 喂 added_line_hits(注释行/删除行/豁免行都要滤掉,行号从 @@ 头起算)
  got_b=$(printf '%s\n' \
    '+++ b/NemoNotch/Foo.swift' \
    '@@ -10,2 +10,3 @@' \
    ' context line' \
    '+.animation(.easeInOut.repeatForever(autoreverses: true))' \
    '+        // repeatForever 注释提及不算' \
    '+.repeatForever(autoreverses: true) // fence: allow' \
    '-.repeatForever(autoreverses: true)' \
    | added_line_hits 'repeatForever')
  want_b='NemoNotch/Foo.swift:10:.animation(.easeInOut.repeatForever(autoreverses: true))'
  if [ "$got_b" != "$want_b" ]; then
    echo "❌ selftest: B 档新增行 — 期望「${want_b}」实得「${got_b}」" >&2; fails=$((fails + 1))
  fi
  # **真模式(含反斜杠)也必须过一遍 B 档执行器**(评审 F2):repeatForever 无
  # 反斜杠,探不出「-v 剥反斜杠」这类只有含 `\.` 模式才踩的雷。
  got_o=$(printf '%s\n' \
    '+++ b/NemoNotch/Bar.swift' \
    '@@ -3,1 +3,3 @@' \
    '+.opacity(probe ? 0 : 1)' \
    '+.opacity(dim ? 0.5 : 1)' \
    | added_line_hits "$PAT_OPACITY_HIDE") || {
      echo "❌ selftest: B 档执行器出错(opacity 真模式)" >&2; exit 1; }
  want_o='NemoNotch/Bar.swift:3:.opacity(probe ? 0 : 1)'
  if [ "$got_o" != "$want_o" ]; then
    echo "❌ selftest: B 档 opacity(真模式含反斜杠)— 期望「${want_o}」实得「${got_o}」" >&2; fails=$((fails + 1))
  fi
  if [ "$fails" -gt 0 ]; then
    echo "arch selftest:$fails 条样本失败" >&2; exit 1
  fi
  echo "✅ arch selftest:全部样本(含 B 档合成 diff)符合预期"
  exit 0
  ;;
--all)
  validate_patterns
  echo "🏗  架构围栏全仓体检(--all:A 档拦语义,B 档信息性列举)"
  run_a_tier
  list_b_tier_repo
  if [ "$violations" -gt 0 ]; then
    echo "arch check(--all):$violations 条 A 档规则命中" >&2; exit 1
  fi
  echo "✅ 架构围栏(--all):A 档全绿"
  exit 0
  ;;
"")
  validate_patterns
  echo "🏗  架构围栏(A 档全仓 + B 档本分支新增行)"
  run_a_tier
  run_b_tier
  if [ "$violations" -gt 0 ]; then
    echo "arch check:$violations 条规则命中 — 修掉,或在确认合法处行尾加 // fence: allow 并在评审说明" >&2
    exit 1
  fi
  echo "✅ 架构围栏:全部通过"
  exit 0
  ;;
*)
  echo "用法:sh scripts/check-arch.sh [--all|--selftest]" >&2; exit 2 ;;
esac
