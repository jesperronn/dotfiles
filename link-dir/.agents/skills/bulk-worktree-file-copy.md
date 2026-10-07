---
name: bulk-worktree-file-copy
description: Copy files from a master commit across multiple projects using isolated worktrees and feature branches
---

# bulk-worktree-file-copy

Copy files from a master/main commit across multiple projects using isolated worktrees and feature branches. For when you need to apply the same file changes (e.g. `bin/bump_version`) to N repos based on a single source commit.

## When to use
- One commit in one repo contains file changes you want to replicate to other repos
- Repos share a common structure (e.g. all have `bin/bump_version`)
- You want isolated worktrees + feature branches, not direct master changes

## Critical rules

### 1. Worktree location — NEVER use `.git/worktrees/`
Create worktrees at `<project>/.worktrees/<name>/`, **never** `.git/worktrees/`.

Why: `.git/worktrees/` breaks git's `includeif.gitdir` config rules (common in monorepos with per-repo identity configs like `~/.gitconfig_nine`). It causes stale HEAD/symref issues where the worktree points at old commits or the wrong author.

```bash
# WRONG
git worktree add .git/worktrees/<name> master

# CORRECT
git worktree add <project>/.worktrees/<name> master
```

### 2. Honor per-repo git identity
Don't hardcode `-c user.name/user.email`. Let git resolve the real identity via `includeif.gitdir` rules.

To find the correct identity for a repo:
```bash
# Probe what a commit would actually use (includeif fires at commit time)
git commit --allow-empty -m "probe" && git log -1 --format="%an <%ae>"
```

For monorepos with `~/.gitconfig_nine` (email `jrj@nine.dk`), the resolved identity is often `Name <jrj@nine.dk>`, NOT the base `.gitconfig_local` value.

### 3. Create a feature branch, never push to master
- Branch name: `<feature>-fix` or similar (e.g. `bump-version-fix`)
- Always based off `master` (or `main` if that's the default)
- Push to a **new branch**, never overwrite `master`

### 4. Preserve original commit metadata
When rewriting commits (e.g. to fix author), preserve the original date:
```bash
GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
  git commit-tree <tree> -p <parent> -m "<message>"
```

## Workflow

### Extract files from source commit
```bash
# Get file contents from the source commit (exists only in one repo)
git -C <source_repo> show <commit>:<file> > /tmp/<file>
```

### For each target repo:
```bash
cd <monorepo>
for repo in <repos>; do
  wt="<repo>/.worktrees/<branch>-<repo>"
  
  # 1. Create worktree from master
  git -C "$repo" worktree add --force "$wt" master
  
  # 2. Copy files from staging area
  cp /tmp/<file> "$wt/<path>"
  
  # 3. Commit with correct author (git resolves identity via includeif)
  git -C "$repo" -C "$wt" \
    -c user.name="<real name>" -c user.email="<real email>" \
    commit -m "<commit message>"
  
  # 4. Create feature branch and push
  git -C "$repo" branch -f "$branch"  # after fixing local branch ref
  git -C "$repo" push --force-with-lease origin "$branch"
done
```

### Fixing author on already-pushed commits
If you pushed with wrong author, rewrite via `commit-tree` preserving date:
```bash
local_tip=$(git rev-parse <branch>)
parent=$(git rev-list --parents -1 "$local_tip" | cut -d' ' -f2)
msg=$(git log -1 --format=%B "$local_tip")
date=$(git log -1 --format=%ci "$local_tip")
tree=$(git rev-parse "$local_tip^{tree}")
new_commit=$(echo "$msg" | git commit-tree "$tree" -p "$parent" -m "$msg")
```

Then force-push: `git push --force-with-lease origin <branch>`

## Common pitfalls

### Worktree blocks branch updates
A worktree checking out a branch prevents `git branch -f` from updating it. Fix order:
1. `git worktree remove --force <worktree>`
2. Update the branch: `git branch -f <branch> <sha>`
3. Re-add worktree: `git worktree add <worktree> <branch>`

### Stale HEAD after moving worktrees
When recreating worktrees at new paths, ensure local branch points at correct SHA before re-adding, otherwise worktree checks out old commit.

### git config get doesn't evaluate includeif
`git config get user.email` returns base value, **not** the includeif-resolved value. Use a commit probe to see actual identity.

## Verification
```bash
# Check worktree location (should be <project>/.worktrees/, not .git/worktrees/)
git worktree list --porcelain

# Verify author on remote branch
git ls-remote origin <branch> | awk '{print $1}' | xargs -I{} git cat-file -p {}
```
