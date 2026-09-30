#!/bin/sh
# One-time per-clone setup for NemoNotch git guards + worktree workflow.
# Run from anywhere inside the repo:  sh .githooks/install.sh
#
# Copies hooks/scripts OUT of the working tree into the shared .git dir so they
# stay active on every branch and every worktree (independent of what is checked
# out). Re-run after editing anything under .githooks/.
set -e

root=$(git rev-parse --show-toplevel)
common=$(git rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$root/$common" ;; esac

hooks="$common/hooks"
bin="$common/nemonotch-bin"
src="$root/.githooks"

mkdir -p "$hooks" "$bin"
cp "$src/pre-commit"       "$hooks/pre-commit"
cp "$src/pre-merge-commit" "$hooks/pre-merge-commit"
cp "$src/post-merge"       "$hooks/post-merge"
cp "$src/feat.sh"          "$bin/feat.sh"
cp "$src/feat-done.sh"     "$bin/feat-done.sh"
chmod +x "$hooks/pre-commit" "$hooks/pre-merge-commit" "$hooks/post-merge" "$bin/feat.sh" "$bin/feat-done.sh"

git config alias.feat      "!sh \"$bin/feat.sh\""
git config alias.feat-done "!sh \"$bin/feat-done.sh\""
git config alias.feat-list "worktree list"
git config pull.ff only
git config branch.develop.rebase true
git config branch.develop.mergeoptions "--no-ff"

echo "✅ NemoNotch git guards installed"
echo "   hooks   : $hooks/{pre-commit,pre-merge-commit,post-merge}"
echo "   aliases : git feat <name> | git feat-done <name> | git feat-list"
echo "   config  : pull.ff=only · branch.develop.rebase=true · branch.develop.mergeoptions=--no-ff"

# lint 门禁依赖 swiftlint + swiftformat;缺工具时 pre-commit 会拦截提交(防假绿)。
missing=""
for tool in swiftlint swiftformat; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  echo "⚠️  未安装:$missing — pre-commit lint 会拦截提交。安装:brew install$missing"
fi
