#!/bin/sh
# NemoNotch 文档对账门禁 — 权威源文档(AGENTS.md / CI 注释)与代码的「成对断言」。
#
# 起因(2026-10-20 实测):AGENTS.md 架构图与 opencode 段仍写 /tmp/nemonotch.sock
# 与 "Unix socket",而 HookServer 自 27cb231(2026-05-16)起就是 127.0.0.1 TCP —
# 漂了 5 个月才被抓到;codeql.yml 的文件数注释(27/143)同样过期(实测 56/233)。
# 「同步更新手册」是立下的规则,不是自动达成的事实 — 数字与架构断言必须机器对账。
#
# 每条检查都是「成对断言」:代码侧的 grep 与文档侧的 grep 写在一起。代码改了
# 传输方式 / 目录布局时,本脚本的断言与 AGENTS.md 必须在同一个提交里更新 —
# 这个强迫同行正是本脚本存在的目的。新增漂移高发点时往这里加检查,并在检查
# 上方注明驱动的漂移实例与日期;纯历史叙述(修复簇复盘)不要写成会撞检查的
# 现在时断言。
#
# Usage:
#   sh scripts/doc-audit.sh    # 全部检查;退出码非零 = 有断言失败
# CI:.github/workflows/doc-audit.yml(push/PR 到 main/develop 时跑,纯 grep,ubuntu)。
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

fail=0

echo "📄 文档对账(doc-audit)— 成对断言逐条检查"

# ── 1. HookServer 传输方式:代码(NWListener on 127.0.0.1)↔ AGENTS.md ──
# 漂移实例:2026-10-20 实测 AGENTS.md:127(架构图)/:192(opencode 段)落后
# 27cb231(2026-05-16)整整 5 个月 — 本门禁的第 1 号驱动事故。
if grep -q 'NWListener' NemoNotch/Services/HookServer.swift; then
  if grep -qn 'nemonotch.sock' AGENTS.md; then
    echo "❌ AGENTS.md 仍引用已废弃的 /tmp/nemonotch.sock(代码自 27cb231 起是 127.0.0.1 TCP)" >&2
    fail=1
  fi
  if ! grep -q 'HookServer<br/>127.0.0.1 TCP' AGENTS.md; then
    echo "❌ AGENTS.md 架构图的 HookServer 节点未标注 '127.0.0.1 TCP'(传输方式变了就和代码一起改这里)" >&2
    fail=1
  fi
  if grep -q 'HookServer` Unix socket' AGENTS.md; then
    echo "❌ AGENTS.md 仍把 HookServer 描述为 Unix socket(现为 127.0.0.1 TCP loopback)" >&2
    fail=1
  fi
  if [ "$fail" = 0 ]; then
    echo "✅ HookServer 传输方式:代码(NWListener)与 AGENTS.md(127.0.0.1 TCP)一致"
  fi
else
  echo "❌ HookServer.swift 不再包含 NWListener — 传输方式变了?把本断言、AGENTS.md 架构图与 opencode 段在同一个提交里改掉" >&2
  fail=1
fi

# ── 2. INFOPLIST_KEY_* 双配置(pbxproj 里 Debug/Release 各恰好一份)──
# 依据:AGENTS.md「Info.plist Configuration」— 漏改一份 = 一套构建弹权限、
# 另一套静默不弹的错位,极难归因。2026-10-20 实测 6 个 key 均为 2 份。
bad_keys=$(grep -o 'INFOPLIST_KEY_[A-Za-z]*' NemoNotch.xcodeproj/project.pbxproj | sort | uniq -c | awk '$1 != 2 {print $2}')
key_total=$(grep -o 'INFOPLIST_KEY_[A-Za-z]*' NemoNotch.xcodeproj/project.pbxproj | sort -u | wc -l | tr -d ' ')
if [ "$key_total" = "0" ]; then
  echo "❌ project.pbxproj 里一个 INFOPLIST_KEY_* 都没有了 — 配置丢失,不是「通过」" >&2
  fail=1
elif [ -n "$bad_keys" ]; then
  echo "❌ 这些 INFOPLIST_KEY_* 在 project.pbxproj 不是恰好 2 份(Debug+Release 各一):$bad_keys" >&2
  fail=1
else
  echo "✅ INFOPLIST_KEY_* 共 ${key_total} 个,全部双配置"
fi

# ── 3. 嵌套 worktree 三重隔离(gitignore + lint 排除 + format 排除)──
# 依据:docs/git-worktree-workflow.md — 缺一处,嵌套副本就会被全仓 lint 当源码扫、
# 被 git add -A 暂存成嵌套仓库。
wt_ok=1
for f in .gitignore .swiftlint.yml .swiftformat; do
  if ! grep -q '\.worktree' "$f"; then
    echo "❌ $f 缺少 .worktree 排除(三重隔离缺一不可)" >&2
    wt_ok=0
    fail=1
  fi
done
if [ "$wt_ok" = 1 ]; then
  echo "✅ 嵌套 worktree 三重隔离在位(.gitignore / .swiftlint.yml / .swiftformat)"
fi

# ── 4. CLAUDE.md 是指向 AGENTS.md 的符号链接(单一权威入口)──
# 两份入口文档必然漂移;符号链接让工具读到的那份就是维护的那份。
link=$(readlink CLAUDE.md 2>/dev/null || true)
if [ "$link" != "AGENTS.md" ]; then
  echo "❌ CLAUDE.md 应是指向 AGENTS.md 的符号链接(当前:'${link:-缺失或为普通文件}')" >&2
  fail=1
else
  echo "✅ CLAUDE.md → AGENTS.md 符号链接在位"
fi

# ── 5. 本地部署签名身份:build.sh ↔ AGENTS.md(2026-10-20 起)──
# 证书本体只活在开发机登录钥匙串,CI 上不存在 — 所以断言的是「同一身份名
# 同时登记在 build.sh 与本手册」,不是证书存在性(那在 CI 会假红)。发布
# DMG(release.yml)刻意保持 ad-hoc:无公证的自签在 Gatekeeper 面前与
# ad-hoc 等价,稳定身份只对本地装机的 TCC/Keychain 有意义。
if grep -q 'NemoNotch Local Code Signing' build.sh && grep -q 'NemoNotch Local Code Signing' AGENTS.md; then
  echo "✅ 本地部署签名身份:build.sh 与 AGENTS.md 登记一致(NemoNotch Local Code Signing)"
else
  echo "❌ 本地部署签名身份漂移:build.sh 与 AGENTS.md 必须同时登记 'NemoNotch Local Code Signing'(改名要脚本、手册、证书三处一起换)" >&2
  fail=1
fi

# ── 6. 手册引用的脚本必须存在(文档引用已删除/改名脚本的通用守卫,2026-10-20)──
# scripts/ 与 .githooks/ 下的引用按路径精确检查;根目录裸名(build.sh、
# release.sh、test.sh 简写)须存在于仓库根 / scripts/ / .githooks/,或是代码在
# 运行时写出的产物(Swift 源码里出现该文件名即视为已知产物 — hook-sender.sh
# 由 HookInstaller 生成、不在仓库里,实测 2026-10-20,没这条会误报)。
refs_ok=1
# 两处都要求 .sh/.py 之后是词边界:没有它,"CompletionFlashService.showCompletionToast"
# 会被切出一个假的 "CompletionFlashService.sh"(2026-10-20 首跑即误报)。
for ref in $(grep -oE '(scripts/[A-Za-z0-9_.-]+\.(sh|py)|\.githooks/[A-Za-z0-9_.-]+\.sh)([^A-Za-z0-9_]|$)' AGENTS.md | sed 's/[^A-Za-z0-9_.]*$//' | sort -u); do
  if [ ! -e "$ref" ]; then
    echo "❌ AGENTS.md 引用的脚本不存在: $ref(删了/改名了?手册要跟上)" >&2
    refs_ok=0; fail=1
  fi
done
for name in $(grep -oE '(^|[^A-Za-z0-9_./-])[A-Za-z0-9_-]+\.sh([^A-Za-z0-9_]|$)' AGENTS.md | sed 's/^[^A-Za-z0-9_-]*//; s/[^A-Za-z0-9_.]*$//' | sort -u); do
  if [ ! -e "$name" ] && [ ! -e "scripts/$name" ] && [ ! -e ".githooks/$name" ] \
     && ! grep -rqF "$name" NemoNotch --include='*.swift'; then
    echo "❌ AGENTS.md 引用的脚本 $name 既不在仓库根 / scripts/ / .githooks/,也不是代码生成物" >&2
    refs_ok=0; fail=1
  fi
done
if [ "$refs_ok" = 1 ]; then
  echo "✅ 手册引用的脚本全部存在(scripts/ .githooks/ 精确路径 + 根目录裸名)"
fi

echo "──────────────────────────────"
if [ "$fail" = 0 ]; then
  echo "✅ 文档对账通过(退出码 0)"
  exit 0
fi
echo "❌ 文档对账失败 — 上面每条 ❌ 都是文档(或代码)需要跟上的地方。" >&2
echo "   修完重跑: sh scripts/doc-audit.sh" >&2
exit 1
