#!/usr/bin/env bash
# supermemory SessionStart hook.
#
# Injects strong, top-of-session guidance via `additionalContext` so the agent
# routes save/recall through the supermemory MCP tools instead of the system
# prompt's built-in file-based "auto memory" path.
#
# The MCP tool descriptions alone are not enough — Claude Code ships with a
# system-prompt section that directs the agent to write memory files under
# ~/.claude/projects/<slug>/memory/. Without an explicit override at session
# start, that path wins by default. This hook is the override.
#
# Wire: registered by install.sh under hooks.SessionStart in settings.json,
# identified by path substring `supermemory/hooks/session-start.sh` so the
# uninstaller can strip it cleanly. No env required — it just emits text.
set -u

# Skip when the user has explicitly disabled the nudge.
[ "${SUPERMEMORY_SESSION_NUDGE:-1}" = "1" ] || exit 0

cat <<'EOF'
[supermemory] Cross-session memory for this user is backed by the supermemory MCP server.

Tools: `mcp__supermemory__memory` (action: "save" | "forget"), `mcp__supermemory__recall`, `mcp__supermemory__whoAmI`.

This is the SINGLE source of truth for remembering things across conversations. DO NOT use the file-based "auto memory" system described in the system prompt's `auto memory` section — do NOT write to `~/.claude/projects/<slug>/memory/` and do NOT create or update `MEMORY.md`. That backend is disabled in favor of the MCP tools.

Projects are auto-scoped from the working directory: every save/recall lives under a slug derived from the current git repo (or cwd basename). Pass an explicit `project` only when the user is talking about a different repo than the one they're cd'd into. Otherwise omit it and the right bucket is selected automatically.

PROACTIVELY call `mcp__supermemory__memory` with action="save" when the user has CONCLUDED something — not when they're brainstorming or you're inferring intent. Concrete signals to save:
- The user states a preference, working-style rule, or constraint in their own words ("I prefer X", "always Y", "never Z").
- The user states a fact about themselves, their role, team, stack, or product.
- The user explicitly assents to a non-obvious assistant proposal ("yes do that", "that bundled PR was the right call").
- The user gives concrete corrective feedback that should change future behavior ("stop doing X", "use Y instead").
- The user names an external resource (Linear project, Slack channel, dashboard, runbook) future-you would need to find again.
- The user shares a project goal, deadline, constraint, or stakeholder context not derivable from the code.
Use action="forget" when the user contradicts, supersedes, or invalidates a previously-stated preference, or asks you to drop a memory. Pair it with a save when they're refining ("actually it's X not Y").

DO NOT save speculation, rejected proposals, ephemeral task state, code patterns derivable from the repo, or anything already in CLAUDE.md.

Call `mcp__supermemory__recall` when:
- The user asks something that depends on prior context about them or their projects.
- The user references past work ("like we did before", "the usual way").
- You're starting a non-trivial task and want relevant prior context — query once up front.

Two background hooks complement the MCP tools:
- A `UserPromptSubmit` hook auto-injects relevant memories on every prompt — if you see a `[supermemory] Relevant saved memories (auto-recalled):` block, recall already ran.
- A `Stop` hook runs an extractor LLM over the most recent exchange (user + assistant + any follow-up) and persists confirmed conclusions / forgets contradicted memories. The agent's own MCP saves remain authoritative — explicit calls always win over the background extractor.
EOF
