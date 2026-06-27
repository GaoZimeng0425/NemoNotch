# Git Worktree Workflow & Branch Guards

This repo enforces its Git Flow with local hooks + aliases that travel with the
repo. They let you develop several features at once (one worktree each) while
making it impossible to accidentally diverge `main` the way it happened before
(local `main` was advanced by local merges that were never pushed — see the
incident write-up below).

## One-time setup (every clone / machine)

```sh
sh .githooks/install.sh
```

This copies the hooks and helper scripts **out of the working tree into the
shared `.git` dir**, so they stay active on every branch and every worktree
regardless of what is checked out. Re-run it after editing anything in
`.githooks/`.

What it configures:

| Item | Effect |
|------|--------|
| `pre-commit` hook | Blocks direct commits on `main`/`master`. On `develop`, a conflict-resolved merge must come from `feature/*` or `hotfix/*`. |
| `pre-merge-commit` hook | Blocks merge commits on `main`/`master` (PR-only). On `develop`, only `feature/*` / `hotfix/*` (and `origin/develop` self-sync) may merge. |
| `pull.ff = only` | `git pull` on any branch refuses a silent merge — divergence errors out immediately. |
| `branch.develop.rebase = true` | `git pull` on `develop` rebases (stays linear, no ff-only block). |
| `branch.develop.mergeoptions = --no-ff` | Feature merges into `develop` always keep a merge commit. |

> Hooks are **local** and not synced automatically — every clone must run the
> installer once. Bypass any guard in an emergency with `--no-verify`.

## Daily commands

```sh
git feat <name>        # feature/<name> off local develop, in a sibling worktree
                       #   ../NemoNotch-worktrees/<name>
                       #   (warns if local develop is behind origin/develop)
cd ../NemoNotch-worktrees/<name>
# ...work, commit freely on the feature branch...

git feat-done <name>   # merge feature/<name> -> develop (--no-ff), remove worktree,
                       #   delete the branch
git feat-list          # list all worktrees
```

Run several `git feat` in a row to have multiple features checked out side by
side, each in its own directory — no branch switching, no stash juggling.

`git feat-done` run from *inside* the target worktree can't delete its own
directory; it will merge and then print the `cd` + `git worktree remove` command
to finish.

## Branch rules (what the guards enforce)

- **main** — never touched locally. Advances only via GitHub "Merge pull
  request" of `develop`. Locally: `git pull --ff-only` to mirror. Treat it as
  read-only here.
- **develop** — integration branch. Direct commits for small fixes are fine;
  features come in via `feature/*` merges (`--no-ff`).
- **feature/* , hotfix/*** — where real work happens, preferably in a worktree.

## Background: why these guards exist

On 2026-06-26 the local `main` showed a 490/530 divergence from `origin/main`
with byte-identical content but completely different SHAs. Root cause: `main`
was being advanced **two ways in parallel** — GitHub's PR-merge button
(canonical) *and* local `git merge develop` (never pushed). Every merge commit
differed, so the whole post-fork history re-hashed. `git pull` (default merge)
then kept stacking merge commits and never converged. Fix was
`git reset --hard origin/main`; these guards prevent a recurrence.
