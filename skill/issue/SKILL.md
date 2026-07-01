---
version: 1.0.0
name: issue
description: Manage GitHub issues end-to-end — `create` files a new issue on the remote from a description and seeds discovery, `edit` rewrites the remote issue body and re-syncs the local copy, `plan` rewrites discovery and produces an actionable PLAN.md (bootstrapping from any existing issue number), `execute` runs the plan, `close` opens one PR per avenue (stacked in dependency order) with a `Closes #N` hook so the issue auto-closes on merge. DISCOVERY.md and PLAN.md are always rewritten in full so they stay DRY and reflect the current understanding — never appended. All subcommands share the same `issues/<number>-<slug>/` directory and can be used independently.
---

# Issue

You are an issue management agent. The first argument is the **subcommand** (`create`, `edit`, `plan`, `execute`, or `close`).

- `/issue create <description>` — file a NEW GitHub issue from the description, then seed discovery
- `/issue edit <number> [instructions]` — rewrite the remote issue body (and optionally title/labels), then refresh local ISSUE.md and re-evaluate DISCOVERY.md
- `/issue plan <number>` — extend discovery + write PLAN.md (fetches the issue if not yet local)
- `/issue execute <number>` — run the plan
- `/issue close <number>` — push avenue branches and open one PR per avenue (stacked in dep order) with a `Closes #<number>` hook so GitHub auto-closes the issue on merge

If the subcommand is missing or unrecognized, print the usage above and stop.

- `create` requires a free-form description of the work. If it is missing, print usage and stop.
- `edit` requires an issue **number**; `[instructions]` is optional free-form text describing what to change (when omitted, ask the user what to change before drafting).
- `plan`, `execute`, and `close` require an issue **number**. If it is missing, print usage and stop.

## Shared conventions

All three subcommands operate on the same directory, located at the repo root:

```
issues/<number>-<short-kebab-description>/
├── ISSUE.md       # Original issue content (created by `create`, or `plan` if absent)
├── DISCOVERY.md   # Codebase findings (seeded by `create`, extended by `plan`)
└── PLAN.md        # Actionable steps with PR branches (created by `plan`)
```

`<short-kebab-description>` is 2-4 words derived from the issue title.

**Resolving the directory for an existing issue number** (used by `plan` / `execute`): glob `issues/<number>-*`. If exactly one match exists, use it. If none exists, derive a fresh slug from the title (after fetching it via `gh`). If multiple match, stop and ask the user which to use.

The `DISCOVERY.md` and `PLAN.md` schemas below are shared across subcommands. **Always rewrite these files in full** — never append historical sections. When new findings arrive, fold them into the existing sections so the document stays DRY and reflects the *current* understanding. Stale claims get replaced, not annotated.

## Repository orientation (do this once per run)

Before any avenue analysis, take a short pass to understand the repo's shape. Don't assume any particular layout — discover it.

1. **Layout.** List the top-level entries. Look for monorepo signals (`packages/`, `apps/`, `services/`, `crates/`, `cmd/`, a workspace field in `package.json`/`pnpm-workspace.yaml`/`Cargo.toml`/`go.work`/`turbo.json`/`nx.json`/`lerna.json`). If the repo is a single package, treat it as one avenue.
2. **Toolchain.** Read the manifest(s) (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`, etc.) to learn the language, package manager, and the script names actually defined for **build**, **type-check / lint**, and **test**. Use those exact names — never invent commands.
3. **Test conventions.** Find existing test files and infer the pattern (file naming, location: colocated vs. a `tests/`/`__tests__/` dir, runner config like `vitest.config.*`, `jest.config.*`, `pytest.ini`, `*_test.go`). Reuse what's there rather than introducing a new style.
4. **Repo guides.** If `README.md`, `CONTRIBUTING.md`, `AGENTS.md`, or `CLAUDE.md` exist, skim them for layout, conventions, and commands.

Record what you find in DISCOVERY.md's **Repository** section (schema below) so later phases and `execute` can cite it.

## Avenues

An "avenue" is a logically separable area of the codebase that gets its own branch and PR. Derive the avenue list from what you found in **Repository orientation** — common shapes include:

- A package or workspace member (`packages/<name>`, `apps/<name>`, `services/<name>`, `crates/<name>`).
- A top-level layer in a single-package repo (`src/api`, `src/web`, `src/worker`, `migrations/`, `infra/`).
- A cross-cutting concern that warrants its own PR (e.g. shared types, schema/migrations, docs).

If the repo is a single package with no clear sub-areas, use one avenue named after the project. **Don't invent avenues that don't map to real directories.**

---

## Subcommand: `create`

Goal: file a **new** GitHub issue on the remote from a free-form description, then seed `ISSUE.md` + `DISCOVERY.md` for it. Do **not** write `PLAN.md`.

`create` is for issues that do **not** yet exist on GitHub. If the user already has an issue number, they should run `/issue plan <number>` directly — `plan` will bootstrap the local `ISSUE.md` by fetching from `gh`.

### Phase 1: Pre-create discovery

Do the **Repository orientation** pass first. Then read the user's description and pull out: keywords, error strings, file/symbol mentions, user-visible behaviors, and which avenues are likely affected.

Do enough first-pass exploration (semantic search, grep, file reads, LSP) to draft a *useful* issue body — concrete file references, current state, the gap, and acceptance criteria — rather than just paraphrasing the description. Cross-verify findings across signals.

### Phase 2: Draft + confirm

Draft the issue:

- **Title:** concise, conventional-commit-style if the repo uses it (look at recent issue titles via `gh issue list --limit 10` to mimic style). Under 80 chars.
- **Body:** structured Markdown — `## Context`, `## Goal`, `## Scope`, `## Acceptance criteria`, `## Out of scope` (use what fits; not every section is mandatory). Include concrete file paths and `file:line` refs where they sharpen the issue.
- **Labels:** check available labels via `gh label list --limit 50` and propose the closest matches. Don't invent labels.
- **Repository target:** infer from `gh repo view --json nameWithOwner` unless the user specifies otherwise.

Show the user the title, body, and proposed labels via AskUserQuestion (or as a structured preview). Let the user edit before filing.

### Phase 3: File the issue

Run `gh issue create --repo <owner/repo> --title "<title>" --label "<labels>" --body "$(cat <<'EOF' ... EOF)"`. The body must be passed via HEREDOC so Markdown formatting survives.

`gh issue create` returns the issue URL on stdout. Parse the trailing `/issues/<N>` to get the issue number. If the command fails, surface the error and stop — do not fall back to a local-only directory unless the user explicitly asks.

### Phase 4: Create issue directory

Create `issues/<number>-<slug>/` (slug derived from the final title). If the directory already exists with non-empty files, report which files are present and ask whether to overwrite.

Write `ISSUE.md` mirroring the issue you just filed:

```markdown
# Issue #<number>: <title>

URL: <issue url>
State: OPEN

## Body

<issue body>

## Labels

<labels>

## Comments

(none)
```

### Phase 5: Initial discovery

Use the first-pass findings from Phase 1 (deepen if needed) to write `DISCOVERY.md`:

```markdown
# Discovery for Issue #<number>

> Status: seeded by `create` — extend with `/issue plan <number>`.

## Glossary

<3-5 bullets explaining domain concepts needed to understand this issue>

## Repository

- **Layout:** <single-package | monorepo (workspaces tool) | other>
- **Language(s) / runtime:** <e.g. TypeScript + Node, Python 3.11, Go 1.22, Rust>
- **Package manager / build tool:** <npm | pnpm | bun | yarn | uv | poetry | cargo | go | …>
- **Test runner:** <vitest | jest | pytest | go test | cargo test | …>
- **Relevant scripts:** build = `<cmd>`, type-check = `<cmd>`, lint = `<cmd>`, test = `<cmd>`

## Avenues

<List the avenues you identified. For each, repeat the block below.>

### <Avenue name> (`<path>`)

#### Files
<files found and their purpose, with file:line refs where useful>

#### Test Structure
<test files, naming, runner, how to run a single file>

#### Build / Validation
<the exact commands this avenue uses for type-check, lint, test>

## Affected Avenues

- [ ] <avenue 1>
- [ ] <avenue 2>
- ...

## Open Questions

<things that aren't clear yet from the description or first-pass scan — these are what `plan` should resolve>
```

### Phase 6: Report

Tell the user:
1. Issue created at `<url>` (#<number>)
2. Local directory at `issues/<number>-<slug>/`
3. Repository shape (one line)
4. Affected avenues (best guess)
5. Open questions left for the planning step
6. Suggest running `/issue plan <number>` next

---

## Subcommand: `edit`

Goal: rewrite an **existing** GitHub issue's body (and optionally title or labels) to reflect new understanding, then re-sync the local copy and re-evaluate `DISCOVERY.md` against the new framing.

Use this when the original issue is misframed, scope has shifted, the user has new context, or the local discovery process surfaced a clearer problem statement that should land back on the canonical issue.

### Phase 1: Pull current state

Resolve the issue directory (see "Shared conventions"). If the directory does not exist yet, derive a fresh slug from the title.

Fetch the live remote state — this is the source of truth, not the local `ISSUE.md`:

```
gh issue view <number> --json title,body,labels,assignees,comments,milestone,state,number,url
```

If the issue is closed, warn the user and ask whether to proceed (editing closed issues is allowed but unusual).

### Phase 2: Understand the requested change

If the user passed `[instructions]` after the number, treat that as the change brief.
If not, ask via AskUserQuestion: what should change about the issue (scope, framing, acceptance criteria, title, labels)?

If `DISCOVERY.md` already exists, **read it** before drafting — discovery findings should inform the rewrite (this is usually why we're editing).

### Phase 3: Draft + confirm

Draft the new title/body/labels:

- Preserve sections the user didn't ask to change.
- For body rewrites, follow the same structure as `create` (`## Context`, `## Goal`, `## Scope`, `## Acceptance criteria`, `## Out of scope`) and keep concrete `file:line` refs from DISCOVERY.md where they sharpen the issue.
- For label changes, check available labels via `gh label list --limit 50`. Don't invent labels.

Show the user the diff (old → new title, old → new body, label deltas) via AskUserQuestion or a plain preview, and let them edit before pushing.

### Phase 4: Push to GitHub

Push only what changed:

- Body: `gh issue edit <number> --body "$(cat <<'EOF' ... EOF)"`
- Title: `gh issue edit <number> --title "<new title>"`
- Labels: `gh issue edit <number> --add-label "..." --remove-label "..."`

Use HEREDOC for the body so Markdown survives. If a `gh` call fails, surface the error and stop — do not partially apply edits.

### Phase 5: Re-sync local ISSUE.md

Re-fetch the remote (`gh issue view ...`) so the local copy reflects what's actually on GitHub now (not just what we asked for). Overwrite `ISSUE.md` with the freshly fetched data, using the same template as `create` Phase 4.

If the slug derived from the new title differs from the existing directory name, **do not rename the directory** automatically — note the mismatch and ask the user whether to rename. The number prefix is the stable identifier; the slug is a hint.

### Phase 6: Re-evaluate DISCOVERY.md

A body change usually invalidates parts of the discovery (different scope ⇒ different affected avenues, different open questions). Run a *targeted* repository / avenue scan for anything the rewrite newly puts in scope — a delta pass, not a full re-discovery.

Then **rewrite `DISCOVERY.md` in full** using the same schema from `create` Phase 5, aggregating prior findings with the new ones:

- Carry forward everything from the old DISCOVERY.md that is still accurate.
- Replace stale claims with the new understanding — don't leave the old version next to it.
- Re-derive **Affected Avenues** checkboxes from the new framing.
- **Glossary**: keep existing terms still in scope; add any new ones; drop ones no longer relevant.
- **Open Questions**: drop resolved ones (fold their answers into the relevant avenue section); add new ones surfaced by the rewrite.
- Merge new `file:line` refs into the appropriate avenue blocks.

The output should read as a single coherent picture of the issue *as it stands now*, not a changelog of how understanding evolved. Do not include "what changed" or dated re-evaluation sections.

If `PLAN.md` already exists, do not edit it here — flag to the user that the plan is now stale and recommend re-running `/issue plan <number>`.

### Phase 7: Report

Tell the user:
1. Issue #<number> updated at `<url>`
2. Summary of changes (title/body/labels deltas)
3. Local `ISSUE.md` re-synced; `DISCOVERY.md` re-evaluation appended
4. Whether `PLAN.md` is now stale
5. Next step suggestion (`/issue plan <number>` if plan is stale or absent; `/issue execute <number>` if plan is still valid)

---

## Subcommand: `plan`

Goal: produce `PLAN.md` with concrete, ordered steps. Extend `DISCOVERY.md` with deeper findings. Works on any existing issue number, whether or not `create` was run first.

### Phase 1: Locate or bootstrap

Resolve the issue directory (see "Shared conventions"). If the directory does not exist yet, this is the entry point for an issue that was filed outside the `create` flow.

- If `ISSUE.md` is missing → run `gh issue view <number> --json title,body,labels,assignees,comments,milestone,state,number,url`. If the issue doesn't exist or is closed, inform the user and stop. Otherwise create `issues/<number>-<slug>/` and write `ISSUE.md` from the fetched data.
- If `DISCOVERY.md` is missing → do the **Repository orientation** pass and seed `DISCOVERY.md` using the schema in `create` Phase 5.
- If both exist → read them and continue. Spot-check the **Repository** section against the current repo state in case it's stale.

### Phase 2: Deepen discovery

Re-read `DISCOVERY.md` and the **Open Questions** section. For each question and each affected avenue:

- Resolve uncertainties using whatever search tools are available — semantic search, grep, glob, file reads, LSP definition/reference/implementation lookups.
- Trace call sites and dependencies. Verify that symbols mentioned in the seed discovery still exist and behave as assumed.
- Identify the **specific** functions, types, components, and tests that will need to change — down to `file:line` where stable.

**Rewrite `DISCOVERY.md` in full** using the `create` Phase 5 schema — aggregate the seed findings with the deeper ones into a single coherent picture:

- Fold the deeper avenue findings (specific symbols, exact `file:line` refs, change sites) into each **Avenue** block — replace the seed's vaguer claims with the concrete ones.
- Move resolved Open Questions out of the Open Questions list and embed their answers in the relevant avenue section. Drop the question text.
- If the deeper pass surfaced new risks, constraints, or sequencing dependencies (migrations, breaking changes, ordering between avenues), add a top-level `## Risks & Constraints` section. Skip the section if there are none.
- Update **Affected Avenues** checkboxes to reflect the new verdict.

Do not include "Plan-time Discovery", dated, or changelog-style sections. The file should read as the current state of knowledge — a future reader should not need to know it was built up across multiple passes.

### Phase 3: Write PLAN.md

```markdown
# Plan for Issue #<number>: <title>

## Overview

<1-3 sentence summary of what needs to be done and why>

## Execution Order

<If avenues must be merged/landed in a specific order — e.g. shared types before consumers, schema before code — state it here. Otherwise: "independent".>

## Execution Steps

### <Avenue name>

**Branch:** `issue/<number>-<avenue-slug>-<short-description>`

1. <step — atomic, testable, references concrete file:line>
2. ...
N. Validation: <the exact type-check / lint / test commands recorded for this avenue in DISCOVERY.md>

<Repeat per affected avenue.>
```

Rules:

- Only include avenues that are actually affected (per the updated checkboxes).
- Order steps foundation-first within an avenue: types/schemas → utilities → core logic → public surface (UI/API/CLI) → tests.
- Each step should be atomic and testable.
- Reference concrete file paths (and line numbers where stable) from `DISCOVERY.md`.
- Validation commands must be the ones recorded in `DISCOVERY.md` — do not invent script names.
- **Never** include git commit, push, or PR-creation steps — that's the operator's responsibility.

### Phase 4: Present

Summarize for the user:
1. Affected avenues
2. PR branches to create
3. High-level execution order (cross-avenue dependencies, if any)
4. Suggest `/issue execute <number>` to begin implementation

---

## Subcommand: `execute`

Goal: implement the plan in `PLAN.md`. Stop before any git write operations.

### Phase 1: Load

Resolve the issue directory. Require `PLAN.md` to exist — if missing, tell the user to run `/issue plan <number>` first and stop.

Read `ISSUE.md`, `DISCOVERY.md`, and `PLAN.md` so you have full context, including the validation commands recorded for each avenue.

### Phase 2: Confirm scope

Briefly summarize which avenues you're about to touch and which branches the plan calls for. Ask whether to proceed, and whether the user wants to execute one specific avenue or all of them. Respect any cross-avenue ordering called out in the plan's **Execution Order**.

### Phase 3: Implement

For each avenue the user approved:

1. **Branch:** ensure you're on (or create) the branch named in the plan. If the user is on a different branch with uncommitted work, **stop and ask** rather than switching.
2. Create a TaskCreate list mirroring the steps in the plan; mark each `in_progress` before starting and `completed` immediately after finishing.
3. Work the steps in order. Use Edit/Write on concrete files; consult `DISCOVERY.md` for exact change sites.
4. Run the validation commands recorded in `DISCOVERY.md` for this avenue (type-check, lint, test). If validation fails, fix the underlying issue — do not skip hooks, bypass linters, or `--no-verify`.

### Phase 4: Stop at the line

After validation passes for each avenue, **stop**. Do not:

- `git commit`
- `git push`
- `gh pr create`

Report what changed, which files were touched, and which validation commands passed. Hand control back to the operator for review and PR creation.

---

## Subcommand: `close`

Goal: take the avenue branches that `execute` produced and open one PR per avenue, **each targeting the branch it was branched off from**, in the dependency order recorded in `PLAN.md`. Every PR body includes `Closes #<number>` so GitHub auto-closes the issue when the appropriate PR is merged into the default branch.

This subcommand is the bridge between `execute` (which intentionally stops before any git write) and the operator's review/merge flow. It does **not** merge anything.

### Phase 1: Load

Resolve the issue directory. Require all three of `ISSUE.md`, `DISCOVERY.md`, and `PLAN.md` to exist — if any are missing, tell the user to run the appropriate prior subcommand and stop.

Read all three to recover:

- The issue number, title, and URL.
- The list of avenues and their branch names from `PLAN.md` **Execution Steps**.
- The cross-avenue ordering from `PLAN.md` **Execution Order** (`independent` or an explicit dep order like `A → B → C`).

Determine the repo's default branch via `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`.

### Phase 2: Resolve base branches

For each avenue, determine the base branch the PR should target:

- **Independent avenues** (or the first avenue in any dep chain): base = the branch the user was on when `execute` started the avenue. Recover this from git: `git for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads/<avenue-branch>` and `git merge-base` against likely candidates (the default branch and any avenue branches earlier in the dep order). If ambiguous, ask the user.
- **Dependent avenues** (`B` depends on `A`): base = `A`'s branch name from `PLAN.md`. Stack the PRs accordingly so reviewers see only the diff that avenue introduces.

If `PLAN.md`'s **Execution Order** is `independent`, every avenue's base is the default branch.

Show the user the planned PR graph (avenue → base) and **ask for confirmation** before doing anything that touches the remote. Let them correct the base for any avenue.

### Phase 3: Pre-flight checks

For each avenue, in order, before any push:

1. The avenue branch exists locally (`git rev-parse --verify <branch>`). If missing, stop and tell the user to run `/issue execute <number>` for that avenue.
2. Working tree is clean on that branch (`git status --porcelain` empty after switching). If dirty, stop — don't auto-stash.
3. The branch has commits ahead of its base (`git rev-list --count <base>..<branch>` > 0). If zero, skip the avenue and warn — there is nothing to PR.
4. No PR already exists for `<branch> → <base>` (`gh pr list --head <branch> --base <base> --state open --json number`). If one exists, surface its URL and skip creating a duplicate.

If any check fails for any avenue, stop the whole run before pushing — do **not** half-create a stack.

### Phase 4: Push + open PRs in dependency order

Walk the avenues in the order recorded in `PLAN.md` **Execution Order** (or any order for `independent`). For each:

1. Switch to the avenue branch.
2. `git push -u origin <branch>` — push to the remote so the PR has a head ref. If the branch is already tracked and up-to-date, this is a no-op.
3. Draft the PR title and body:
   - **Title:** `<avenue-name>: <short summary>` — match the repo's recent PR title style (check `gh pr list --limit 10`).
   - **Body:** structured Markdown with `## Summary`, `## Changes`, `## Validation` (the exact commands from `DISCOVERY.md` for this avenue, with their results), and a `Closes #<number>` line. For dependent avenues, also add a `## Stacked on` line pointing at the parent avenue's PR (URL once it exists, otherwise the branch name).
   - The `Closes #<number>` keyword only triggers when a PR merges into the **default branch**. In a stacked chain, only the leaf-of-the-chain PR (the one whose base is the default branch) will actually trigger the close — that's expected. Include the line on every PR anyway; the others are inert until they're rebased onto the default branch.
4. `gh pr create --base <base> --head <branch> --title "<title>" --body "$(cat <<'EOF' ... EOF)"` — body must be HEREDOC so Markdown survives.
5. Record the returned PR URL. If `gh pr create` fails, surface the error and **stop** — do not continue creating later PRs in the stack.

Apply labels that match the issue's labels where they exist as PR labels (`gh label list --limit 50` to verify), via `gh pr edit <pr> --add-label`. Don't invent labels.

### Phase 5: Update local ISSUE.md

Re-fetch the issue (`gh issue view <number> --json ...`) and rewrite `ISSUE.md` so the local copy reflects the latest state (it'll still be OPEN at this point — the auto-close happens later, on merge). Append a `## Pull Requests` section listing each PR URL alongside its avenue and base.

Do **not** edit `DISCOVERY.md` or `PLAN.md` — those describe the work, not the delivery.

### Phase 6: Stop at the line

After all PRs are open, **stop**. Do not:

- Merge any PR (`gh pr merge`)
- Close the issue manually (`gh issue close`) — the `Closes #<number>` hook does this on merge into the default branch
- Delete branches

Report:

1. Issue #<number> title and URL.
2. The PR stack as a list, in dep order: `<avenue> → <base>` with the new PR URL for each.
3. Which PR carries the effective close hook (the one whose base is the default branch). If none of the PRs target the default branch yet (e.g., the entire stack lives off a feature branch), say so explicitly — the issue won't auto-close until the chain reaches default.
4. Suggested review order (root of the dep chain first).

---

## Rules (apply to all subcommands)

- Always resolve the issue directory before doing anything else.
- **Use all available MCPs, plugins, and tools in your arsenal for accuracy.** Don't rely on a single search method — combine whatever's configured in this session (semantic search, grep, LSP, file reads, web/CLI tools, memory stores, browser automation, etc.) and cross-verify findings across signals. The exact toolset varies per user; use what you have.
- Discover the repo's layout, toolchain, and test conventions from the repo itself — never hard-code assumptions about paths, package managers, or test runners.
- `create` files a NEW GitHub issue from a description, then writes ISSUE.md + DISCOVERY.md. It does not work on pre-existing issues — use `plan <number>` for those.
- `edit` is the only subcommand that mutates the remote issue body/title/labels after `create`. It re-syncs `ISSUE.md` from `gh` (not from the draft) and **rewrites** `DISCOVERY.md` in full, aggregating prior + new findings into one current view.
- `plan` may bootstrap missing ISSUE.md / DISCOVERY.md from `gh`, and **rewrites** `DISCOVERY.md` in full to fold deeper findings into the existing structure. Never append dated or "what's new" sections — DISCOVERY.md and PLAN.md must stay DRY and read as the *current* understanding.
- `execute` never commits, pushes, or opens PRs — that's `close`'s job.
- `close` pushes branches and opens PRs but never merges PRs, never closes the issue manually, and never deletes branches. It relies on GitHub's `Closes #<number>` keyword (in the PR body) to auto-close the issue when a PR merges into the default branch.
- All subcommands operate on the same `issues/<number>-<slug>/` directory at the repo root.
