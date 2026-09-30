# Git Worktree Workflow & Branch Guards

This repo enforces its Git Flow with local hooks + aliases that travel with the
repo. They let you develop several features at once (one worktree each) while
making it impossible to accidentally diverge `main` the way it happened before
(local `main` was advanced by local merges that were never pushed — see the
incident write-up below). Every commit happens in a worktree, commits pass a
Swift lint gate, and merging into develop automatically builds and installs the
new app.

## One-time setup (every clone / machine)

```sh
brew install swiftlint swiftformat   # lint 门禁依赖;缺工具时 pre-commit 会拦截提交
sh .githooks/install.sh
```

This copies the hooks and helper scripts **out of the working tree into the
shared `.git` dir**, so they stay active on every branch and every worktree
regardless of what is checked out. Re-run it after editing — or pulling a
change that touches — anything under `.githooks/` (installed copies don't
self-update).

What it configures:

| Item | Effect |
|------|--------|
| `pre-commit` hook | Blocks direct commits on `main`/`master` **and in the primary worktree** (all commits live in `git feat` worktrees; concluding a conflict-resolved merge is the only exception). Runs the Swift lint gate on staged `*.swift` (SwiftFormat auto-fix + re-stage, SwiftLint error-level block). Normalizes staged `*.xcstrings`. |
| `pre-merge-commit` hook | Blocks merge commits on `main`/`master` (PR-only). On `develop`, only `feature/*` / `hotfix/*` (and `origin/develop` self-sync) may merge. |
| `post-merge` hook | When develop receives a merge from `feature/*`/`hotfix/*` in the primary worktree, runs `./build.sh` (archive → export → DMG → install to `/Applications` → relaunch). `NEMONOTCH_HOOK_DEBUG=1` dry-runs. |
| `pull.ff = only` | `git pull` on any branch refuses a silent merge — divergence errors out immediately. |
| `branch.develop.rebase = true` | `git pull` on `develop` rebases (stays linear, no ff-only block). |
| `branch.develop.mergeoptions = --no-ff` | Feature merges into `develop` always keep a merge commit. |

> Hooks are **local** and not synced automatically — every clone must run the
> installer once. Bypass any guard in an emergency with `--no-verify`.

## Daily commands

```sh
git feat <name>        # pull latest first: ff-only --autostash develop to
                       #   origin/develop when purely behind (aborts the feat
                       #   if the pull fails), then feature/<name> off the
                       #   refreshed develop, in ../NemoNotch-worktrees/<name>
                       #   (diverged → warns, stays on local develop;
                       #    primary not on develop → warns, skips the pull)
cd ../NemoNotch-worktrees/<name>
# ...work, commit freely on the feature branch (lint gate runs on commit)...

git feat-done <name>   # auto-stash primary checkout → merge feature/<name> -> develop
                       #   (--no-ff, triggers post-merge build) → restore stash
                       #   → remove worktree, delete the branch
git feat-list          # list all worktrees
```

Run several `git feat` in a row to have multiple features checked out side by
side, each in its own directory — no branch switching, no stash juggling.

`git feat-done` run from *inside* the target worktree can't delete its own
directory; it will merge and then print the `cd` + `git worktree remove` command
to finish.

## Swift lint gate

`scripts/lint.sh` is the eslint-style entry point: SwiftFormat (`.swiftformat`,
formatting) + SwiftLint (`.swiftlint.yml`, analysis). Pre-commit invokes it as
`--staged --fix`:

- SwiftFormat auto-fixes staged files and re-stages them. A file that also has
  **unstaged** changes (partial staging) is only *checked*, never rewritten —
  so unstaged hunks can't leak into the commit.
- SwiftLint **error**-level violations block the commit; warnings pass.
- Missing tools block instead of silently skipping (no false green):
  `brew install swiftlint swiftformat`.

Manual runs: `sh scripts/lint.sh` (whole repo, read-only), `--fix` (format
whole repo), `--staged [--fix]` (what the hook does).

## Test gate & independent review

- **`git feat-done` runs the unit tests in the feature worktree *before*
  merging** — merging means auto-deploying to `/Applications`, so tests must
  precede deployment. A failure aborts the merge with the worktree and branch
  intact. Features with no `*.swift` changes skip the gate;
  `NEMONOTCH_SKIP_TESTS=1` is the emergency escape.
- `sh scripts/test.sh` is the manual entry (signing flags built in,
  `--only <TestClass>` to focus, full log → `build/test.log`, exit code printed).
  Report test results by quoting its exit code and log path, never paraphrased.
- **Judge ≠ author:** before `git feat-done`, the feature diff gets an
  independent review (code-review subagent or another session — never the one
  that wrote the change). CI green, lint green, and a successful build are
  signals, not verdicts.

## Branch rules (what the guards enforce)

- **main** — never touched locally. Advances only via GitHub "Merge pull
  request" of `develop`. Locally: `git pull --ff-only` to mirror. Treat it as
  read-only here.
- **develop** — integration branch. Receives `feature/*` merges (`--no-ff`)
  via `git feat-done`; **no direct commits** — the pre-commit hook blocks them
  in the primary worktree (escape hatch: `--no-verify`).
- **feature/* , hotfix/*** — where all work happens, in a `git feat` worktree.

## Background: why these guards exist

On 2026-06-26 the local `main` showed a 490/530 divergence from `origin/main`
with byte-identical content but completely different SHAs. Root cause: `main`
was being advanced **two ways in parallel** — GitHub's PR-merge button
(canonical) *and* local `git merge develop` (never pushed). Every merge commit
differed, so the whole post-fork history re-hashed. `git pull` (default merge)
then kept stacking merge commits and never converged. Fix was
`git reset --hard origin/main`; these guards prevent a recurrence.
