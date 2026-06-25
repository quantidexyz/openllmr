---
name: supermemory
description: Persistent memory + recall backed by local embeddings and sqlite-vec
type: mcp
---

## What it does

Registers an MCP server that gives Claude Code three tools for building
persistent memory across conversations:

- `memory({ content, action: "save" | "forget", project?, destinations? })` —
  save a fact the user shares (preferences, goals, project info) or forget
  one that's outdated. The chunk is keyed on `(saver email, content)` —
  one stored row, one embedding, regardless of how many destinations it
  lives in. Pass `destinations: [{project?, team?}, ...]` to surface the
  same memory in multiple project buckets and/or share with one or more
  teams; the agent's destinations array collapses client-side to a single
  `projects[]` + `teams[]` save call. Re-saving the same content from
  the same user upserts in place — projects unioned, new team refs
  attached, no re-embed. Forget removes the saver's user-ref + their
  team-ref overlays; the underlying chunk only disappears once no other
  user-ref still owns it (so a teammate's co-save is preserved).
- `recall({ query, limit?, project? })` — semantic search over saved
  memories (own + team-shared), markdown-formatted with percent-match and
  project tag.
- `whoAmI()` — identify which gateway account/email/teams this MCP is
  bound to. Useful both for debugging and for discovering team ids you can
  pass back as a destination.

The bundle ships raw text (and queries) to the openllm gateway, which
embeds it with host-paid Bedrock Titan v2 (1024-d) and persists the
vectors in Neon + pgvector scoped to your user id. The bundle never
calls an embedding endpoint directly. Nothing is sent to
`api.supermemory.ai` or any third party.

### Project scoping (no duplicate data)

Project membership is a property of the chunk, not of the storage row.
Each chunk carries `metadata.projects: string[]` — the buckets it
surfaces in. `recall` with a project filters by array containment
(`metadata.projects[] in ["x", ...]`), so a single chunk can appear in
`default`, the cwd-derived project, *and* a topic bucket without any
data being copied. Re-saving the same content with a new bucket unions
the array in place; no new embedding is computed. Slugs must match
`^[a-z0-9][a-z0-9._-]{0,63}$`. Omit project entirely to land in
`default`.

### Team scoping (pointers, not copies)

Team sharing rides on the same chunk via additional ref-overlay tags.
Pass `team`/`teams` (or include `team` inside a `destinations` entry on
the MCP tool) and the gateway calls `appendRefOverlay` for each team —
no second insert, no second embedding. Team members read the chunk
through overlay union (their own user-ref ∪ every team-ref they hold).
The saver always keeps a personal user-ref so they can `forget`, and
forget is ref-counted: the chunk vanishes only when no other user-ref
still owns it. The gateway `/projects` endpoint enumerates the distinct
project slugs the caller can read across personal + team scopes.

### Limits

- `content` max 200,000 chars
- `query` max 1,000 chars
- `project` slug max 64 chars, regex above
- `recall.limit` max 50

## Wiring

```bash
GATEWAY_URL=__GATEWAY_URL__
API_KEY=__API_KEY__
```

The MCP server is registered in `~/.claude.json` (Claude Code's MCP loader
ignores `settings.json`) via `claude mcp add-json -s user supermemory ...`
and runs via `bun run /Users/anon/.litellm/plugins/supermemory/src/index.ts`.

Three hooks live in `~/.claude/settings.json` (where hooks do belong) and are
identified by path substrings so uninstall can strip them cleanly:

- `supermemory/hooks/recall-on-prompt.sh` — `UserPromptSubmit` auto-recall (project-aware)
- `supermemory/hooks/session-start.sh`    — `SessionStart` guidance nudge
- `supermemory/hooks/extract-on-stop.sh`  — `Stop` conversation-grounded extractor (save + forget)

## Session-start guidance hook (the "make the agent actually use it" path)

Install registers a `hooks.SessionStart` entry that runs
`hooks/session-start.sh` once per session and emits an `additionalContext`
block telling the agent:

- Memory is wired through the supermemory MCP tools (`memory`, `recall`,
  `whoAmI`) — this is the SINGLE source of truth.
- Do NOT use the system prompt's built-in file-based "auto memory" path
  (`~/.claude/projects/<slug>/memory/`, `MEMORY.md`). That backend is
  disabled in favor of MCP.
- Concrete triggers for `save` (preferences, working-style rules, feedback,
  external references, project facts) and `recall` (questions about the
  user, references to past work, start of non-trivial tasks).

Without this nudge, the system-prompt's file-based auto-memory section wins
by default and the agent never reaches for the MCP tools. Override via
`SUPERMEMORY_SESSION_NUDGE=0` in the hook env if you need to disable it.

## Auto-recall hook (the "efficient" path)

Install also registers a `hooks.UserPromptSubmit` entry (matched by the
`supermemory/hooks/recall-on-prompt.sh` path substring for clean uninstall)
that runs `hooks/recall-on-prompt.sh` on every user prompt. The hook:

1. Reads the prompt + cwd from the event JSON.
2. Skips trivial prompts (< 6 chars or starting with `!`).
3. Derives a project slug from cwd (git-root basename, slugified;
   falls back to cwd basename) and searches that bucket plus `default`.
4. Calls `/api/plugins/supermemory/search` with a 1.5 s timeout.
5. Injects hits above `SUPERMEMORY_RECALL_MIN_SIMILARITY` (default 0.50)
   as `hookSpecificOutput.additionalContext`.
6. Silently no-ops on any failure — the user never sees an error.

This means the agent gets relevant memories automatically without having
to decide to call `recall` itself. Override behavior via env on the hook
command (edit `settings.json`):

| Var | Default |
|---|---|
| `SUPERMEMORY_RECALL_MIN_SIMILARITY` | `0.50` |
| `SUPERMEMORY_RECALL_LIMIT` | `5` |
| `SUPERMEMORY_RECALL_PROJECT` | _(unset)_ — derived from cwd; set to a slug to hard-pin |
| `SUPERMEMORY_RECALL_MAX_PROMPT` | `1000` (gateway cap) |

## Conversation-grounded extractor (the "smart save / forget" path)

Install registers a `hooks.Stop` entry (`supermemory/hooks/extract-on-stop.sh`)
that runs at the end of each agent turn — *not* on prompt submit. By the time
Stop fires the latest exchange is finished: user statement, assistant
response, and any follow-up are all visible. This is what's needed to
distinguish a confirmed conclusion from a passing speculation.

What it does:

1. Reads the Stop event (`transcript_path`, `cwd`, `session_id`).
2. Derives the project slug from cwd (same logic as the recall hook).
3. Throttles per session: skips if the transcript byte size is unchanged
   since the last extraction, or if `SUPERMEMORY_AUTO_MIN_INTERVAL`
   seconds haven't passed.
4. Pre-fetches `/whoami` (team list) and `/projects` (known slugs the
   caller can read) so the LLM has real destinations to route to. Failures
   here are non-fatal — the hook falls back to project-only routing
   scoped to the cwd-derived slug.
5. Reads the last N transcript turns + the top existing memories for the
   current project, and asks the extractor LLM to emit JSON:
   - `save` — `[{content, destinations: [{project?, team?}, ...]}]`. The
     model picks one or more destinations per save: personal `default`,
     the cwd-derived project, another known project, and/or a team the
     user belongs to. Speculation and rejected ideas are excluded.
     Hallucinated team ids are dropped client-side; the project leg of
     the destination is kept.
   - `forget` — existing memories the latest exchange contradicts,
     supersedes, or invalidates. Update flows naturally: refining a
     preference yields `forget(old) + save(new)`.
6. Applies forgets first, then saves — ONE save per memory item.
   Destinations collapse to `(projects[], teams[])` so the gateway stores
   one chunk and embeds once even when the LLM picked multiple buckets.
   Semantic dedupe is checked across the union of destination projects.
7. All work happens in a detached child — Stop returns immediately.

| Var | Default | Notes |
|---|---|---|
| `SUPERMEMORY_AUTO_SAVE` | `1` | Set `0` to disable extraction entirely |
| `SUPERMEMORY_AUTO_MODEL` | `lite` | Extractor model alias on the gateway |
| `SUPERMEMORY_AUTO_PROJECT` | _(unset)_ | Hard override; otherwise derived from cwd |
| `SUPERMEMORY_AUTO_DEDUPE_SIM` | `0.85` | Skip a save when an existing memory exceeds this similarity |
| `SUPERMEMORY_AUTO_MAX_TURNS` | `12` | Recent transcript turns sent to the extractor |
| `SUPERMEMORY_AUTO_MIN_INTERVAL` | `30` | Min seconds between extractions per session |
| `SUPERMEMORY_AUTO_LOG_DIR` | `~/.claude/plugin-state/supermemory` | save/forget activity log + per-session throttle stamps |

Explicit `mcp__supermemory__memory` calls from the agent remain authoritative
and run synchronously; the extractor only fills the gaps the agent missed.

## Environment

| Var | Required | Default |
|---|---|---|
| `LLM_GATEWAY_URL` | yes | — |
| `LLM_GATEWAY_API_KEY` | yes | — |

<!-- TODO: migrate docs to LITELLMCTL_URL / LITELLMCTL_API_KEY without breaking deployments. -->

Embedding model (`bedrock/titan-embed-v2`, 1024-d) is fixed by the LiteLLM
control plane — not configurable.

## Data layout

Memories live in the gateway's `plugin_chunks` table under collection
`memories`, with vectors in `plugin_chunks_vec_1024`. The chunk id is
`mem_<sha256(saver_email + "\0" + content).slice(0,16)>` — content+saver
only, *not* project. Re-saving the same content by the same user is an
upsert; no second row, no second embedding.

Multi-destination is expressed via two orthogonal mechanisms:
  * **Projects (buckets)** — `metadata.projects: string[]` on the chunk.
    Filtering on `metadata.projects[] in [...]` (array containment, via
    `json_each`) makes one chunk visible in any number of buckets.
  * **Teams (read access)** — additional rows in `plugin_ref_chunks`
    pointing the team's `team:<id>` ref at the same chunk_id. Reads
    union the caller's personal ref with all their team refs.

Forget is ref-counted: the caller's `user:<email>` overlay row is
removed along with any `team:<id>` overlays they're a current member
of. The underlying chunk only disappears once no other user-ref still
points at it. So a memory co-saved by two teammates survives one of
them calling forget — the chunk stays for the remaining owner and the
team continues to recall it.

A one-shot migration runs at gateway startup and rewrites legacy chunks
that only carry `metadata.project` (string) into the new
`metadata.projects: [string]` shape; the legacy field is removed.
