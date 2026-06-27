#!/bin/bash
# release.sh — cut a new release by tagging main and pushing the tag.
#
# Pushing a v* tag triggers .github/workflows/release.yml, which builds the
# DMG and publishes it to GitHub Releases. This script only computes the next
# version, creates the annotated tag, and pushes it.
#
# Usage:
#   ./release.sh [patch|minor|major]
#
#   patch  v0.5.0 -> v0.5.1   (bug fixes)
#   minor  v0.5.0 -> v0.6.0   (new features)
#   major  v0.5.0 -> v1.0.0   (breaking changes)
#
# With no argument it prompts you to pick interactively.
set -euo pipefail

# --- preconditions -----------------------------------------------------------

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$branch" != "main" ]; then
  echo "✋ 发版必须在 main 分支(当前: ${branch:-detached})。" >&2
  echo "   先 git checkout main 并确保已合并 develop。" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "✋ 工作区有未提交改动,请先提交或清理后再发版。" >&2
  exit 1
fi

# Make sure local main matches origin/main so the tag points at published code.
git fetch origin main --tags --quiet 2>/dev/null || true
if git show-ref --verify --quiet refs/remotes/origin/main; then
  if [ -n "$(git rev-list main..origin/main 2>/dev/null)" ] || \
     [ -n "$(git rev-list origin/main..main 2>/dev/null)" ]; then
    echo "✋ 本地 main 与 origin/main 不一致,请先 git pull --ff-only / push。" >&2
    exit 1
  fi
fi

# --- current version ---------------------------------------------------------

latest=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
if [ -z "$latest" ]; then
  latest="v0.0.0"
  echo "ℹ️  未找到现有版本 tag,从 $latest 起算。"
fi

ver=${latest#v}
major=${ver%%.*}
rest=${ver#*.}
minor=${rest%%.*}
patch=${rest##*.}

# --- choose bump -------------------------------------------------------------

bump="${1:-}"
if [ -z "$bump" ]; then
  echo "当前最新版本: $latest"
  echo "选择发版类型:"
  echo "  1) patch  -> v$major.$minor.$((patch + 1))   (bug 修复)"
  echo "  2) minor  -> v$major.$((minor + 1)).0   (新功能)"
  echo "  3) major  -> v$((major + 1)).0.0   (破坏性变更)"
  printf "输入 1/2/3 (或 patch/minor/major): "
  read -r choice
  case "$choice" in
    1|patch) bump="patch" ;;
    2|minor) bump="minor" ;;
    3|major) bump="major" ;;
    *) echo "✋ 无效选择: $choice" >&2; exit 1 ;;
  esac
fi

case "$bump" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
  *)
    echo "✋ 未知发版类型: $bump" >&2
    echo "   用法: $0 [patch|minor|major]" >&2
    exit 1 ;;
esac

new_tag="v$major.$minor.$patch"

# --- confirm & tag -----------------------------------------------------------

echo ""
echo "  $latest  ->  $new_tag  ($bump)"
printf "确认发布 %s ? [y/N] " "$new_tag"
read -r confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "已取消。"; exit 0 ;;
esac

git tag -a "$new_tag" -m "Release $new_tag"
git push origin "$new_tag"

echo ""
echo "✅ 已推送 tag $new_tag,GitHub Actions 正在构建 DMG。"
echo "   进度: https://github.com/GaoZimeng0425/NemoNotch/actions"
