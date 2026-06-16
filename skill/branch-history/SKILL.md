---
version: 1.0.0
name: branch-history
description: Generate or regenerate `BRANCH_HISTORY.md` at the repo root with a Start / Mid / End architectural narrative for the current git branch (relative to its base). Tags the file to the active branch — when invoked on a different branch, offers to reset and regenerate for the new branch. Recomputes from scratch each run using `git log`, `git diff`, file reads, and Agent / MCP exploration tools.
---

# branch-history

A regenerable, branch-tagged architectural changelog. Writes a single file — `BRANCH_HISTORY.md` at the repository root — that explains the branch from its divergence point through to its current HEAD in three sections:

- **Start** — the architecture as it stood at the merge-base (i.e. what the user would see if they checked out the base branch).
- **Mid** — the path from start to current state, organized by architectural theme or pivot rather than commit-by-commit. Major reshapes, deletions, and decisions belong here.
- **End** — the architecture at the current HEAD: data models, routes, integrations, CLI, roles, deployment shape.

Each invocation **recomputes from scratch**. Do not blindly re-emit the previous file — read the git state and the current code, then rebuild.

## When to invoke

- User runs `/branch-history`.
- User asks "summarize this branch", "what changed on this branch", "regenerate the branch history", or similar.

## Procedure

### 1. Detect branch + base

The base is the integration branch this feature branch was actually forked from — **not** automatically `main`. Many repos keep a long-lived `dev` / `develop` / `staging` line that sits between feature branches and `main`; using `main` for those produces a 200-commit, multi-month "history" that's mostly other people's work and obscures the actual branch story.

Step 1a — get the current branch and the candidate set:

```bash
git rev-parse --abbrev-ref HEAD
git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's@^origin/@@'   # default branch
```

Step 1b — for **every** candidate that exists locally or on `origin`, compute its merge-base with HEAD and the commit count from that base to HEAD. Candidates, in this order:

1. `dev`, `develop`, `staging`, `integration`, `next` — long-lived integration branches, if any exist.
2. The default branch from `origin/HEAD` (usually `main`).
3. `main`, `master` — fallback if neither of the above resolves.

For each candidate, prefer `origin/<name>` over the local ref when both exist (the remote is more authoritative for "where did this branch fork from"). Run, in parallel:

```bash
for c in dev develop staging integration next main master; do
  ref=$(git rev-parse --verify --quiet "origin/$c" || git rev-parse --verify --quiet "$c") || continue
  base=$(git merge-base HEAD "$ref")
  count=$(git rev-list --count "$base..HEAD")
  echo "$c $ref $base $count"
done
```

Step 1c — **pick the candidate with the smallest commit count** (i.e. the closest fork point). That is the branch's real base. In the rare case of a tie, prefer the candidate earliest in the priority list above (`dev` before `main`).

Sanity-check the choice with the user before generating, when:
- The chosen base is not `main` / `master` (i.e. you picked an integration branch). Show "Detected base: `<base>` — `<count>` commits ahead of HEAD; main would be `<main-count>`. Use `<base>`?" via `AskUserQuestion`.
- The commit count is suspiciously high (e.g. > 200). The base is probably wrong — surface the alternatives and ask.

Skip the confirmation when the chosen base is `main` / `master` and the commit count is reasonable (< 50 commits) — that's the common case and doesn't need a prompt.

If the current branch IS the chosen base branch, abort with a message — there is no "branch history" for the trunk.

### 2. Check existing file for branch tag

If `./BRANCH_HISTORY.md` already exists, read its first ~15 lines and look for an HTML comment header of the form:

```html
<!--
  branch: <name>
  base:   <base>
  diverged-at: <sha>
  ...
-->
```

- If `branch:` matches the current branch → proceed to **regenerate** (overwrite with a fresh computation).
- If `branch:` is different → use `AskUserQuestion` to confirm:
  - "**Reset to default and regenerate for `<current-branch>`?**" — overwrite the file with a fresh report tagged to the current branch. (Recommended when switching branches.)
  - "**Cancel**" — leave the existing file untouched.

If the file is missing the header or unparseable, treat it as a stale file and offer the same regenerate-vs-cancel choice.

### 3. Gather data (parallelize)

Run as many of the following as apply, in parallel where possible:

- `git merge-base <base> HEAD` → divergence SHA.
- `git log --reverse --pretty='%h %ad %s' --date=short <base>..HEAD` → chronological commit list.
- `git diff --stat <base>..HEAD | tail -3` → totals.
- `git log -1 --format='%H%n%n%B' <pivot-sha>` for any commits that look like architectural turning points (large diffs, "rewrite"/"pivot"/"replace"/"delete" in the subject, large file delete counts).
- `Read` on `./PROGRESS.md`, `./CLAUDE.md`, `./AGENTS.md`, `./doc/architecture.md` if present, to anchor architectural framing.
- `Read` on key entry points (`app/api/**/route.ts`, `src/server/**`, `src/schema/**`) to describe the END section accurately.
- For deeper exploration, spawn an `Explore` Agent with a brief like: *"Map all current top-level domains under `src/server/db/model/` and `src/schema/`, then list every route under `app/api/`. Report under 250 words."*
- If `mcp__claude-context__search_code` is available, use it for conceptual sweeps ("how is auth wired", "where are CRM webhooks handled", etc.) — it's faster than guessing greps.

### 4. Synthesize, don't transcribe

The point of this report is to teach a future reader the **shape and reasoning** of the branch, not to dump the commit log. Group commits by architectural theme; call out pivots (deletions of large amounts of code, re-shaping of core models) explicitly with their SHA. Use prose for narrative, tables for before/after comparisons, code-fence blocks for API/CLI listings.

The Mid section is the substantive one. It should answer: *what major moves did this branch make, in what order, and why?* If the branch went through a rewrite/pivot, that pivot is its own Mid subsection.

### 5. Write the file

Always write to `./BRANCH_HISTORY.md` (root of the repo). The file MUST start with this exact header structure (filled in for the current branch):

```markdown
<!--
  branch: <current-branch>
  base:   <base-branch>
  diverged-at: <merge-base-sha>  (<short-sha>)
  generated-at: <YYYY-MM-DD>
  generator: branch-history skill
  This file is regenerated each time the `branch-history` skill is invoked.
  It is tagged to a specific branch — running the skill on a different
  branch will offer to reset and regenerate.
-->

# Branch history — `<current-branch>`

> Diverged from `<base>` at `<short-sha>` (`<commit subject>`). <N> commits, +<adds> / −<dels> lines net.

<one-paragraph thesis statement>

---

## Start — what `<base>` looked like before the branch opened

…

---

## Mid — the path from start to current state

### <Phase 1 theme>

…

### Pivot 1 — <name> (`<sha>`)

…

### <subsequent phases / pivots>

---

## End — current architecture (HEAD of branch)

### <subsystem>

…
```

The thesis statement is one paragraph. Sections under Mid use ### headings and may be either "Phase N — …" for sustained build-out or "Pivot N — … (`<sha>`)" for sharp rewrites. The End section uses ### subsystem headings and should include data models, scheduling/integration shapes, current API surface (in a code fence), CLI commands, and a `main` vs end-of-branch comparison table.

### 6. Stage + commit

After writing the file, **always offer to commit and push** it for the user. Do not commit without confirmation if there are other unstaged changes (it would be too easy to bundle unrelated work). When committing only `BRANCH_HISTORY.md`, use:

```
docs: regenerate BRANCH_HISTORY.md for <current-branch>

<one-line summary of the most recent architectural state>
```

If the user explicitly approves a push as part of the request, push to the current branch's upstream. Otherwise, leave the commit local and tell the user how to push.

## Constraints

- **Single output file**: only `./BRANCH_HISTORY.md`. Never split across multiple files.
- **No commit log dump**: don't paste `git log` output verbatim. Synthesize.
- **Recompute each run**: read the current state of the codebase fresh; do not assume anything from a previous BRANCH_HISTORY.md.
- **Branch tag is canonical**: the HTML comment header is what differentiates a stale file from a fresh one. Always emit it. Always check it.
- **Off-trunk only**: if HEAD is on `main`/`master`, abort — branch history is meaningless on the trunk.
- **No new dependencies**: this skill uses only `git`, `Read`, `Write`, `Bash`, `AskUserQuestion`, the `Agent` tool (with subagent_type `Explore`), and any available `mcp__claude-context__*` MCP tools.
