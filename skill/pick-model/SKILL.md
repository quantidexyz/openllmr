---
version: 1.0.0
name: pick-model
description: Surface every model exposed by the LitellmCTL gateway as a slash-command autocomplete entry. Type `/m-` in Claude Code and fuzzy-match against the live `/v1/models` list; picking an entry prints the exact `/model <id>` line to activate it.
---

## What this skill does

Claude Code's built-in `/model <id>` command accepts any string your gateway
will route, but the built-in picker (`Cmd+P`) only knows about the bundled
Anthropic models and a single `ANTHROPIC_CUSTOM_MODEL_OPTION`. That's useless
when the gateway exposes a dozen aliases (`ultra`, `plus`, `lite`,
`codex/gpt-5.4`, `kimi-code/...`, `alibaba/...`, …).

This skill fixes discovery:

1. A **SessionStart hook** (installed into `~/.claude/hooks/`) hits
   `GATEWAY_URL/v1/models` at the top of every session.
2. For each returned model, it writes a stub slash-command file to
   `~/.claude/commands/m-<slug>.md` — Claude Code picks those up automatically.
3. Type `/m-` in the prompt — the autocomplete lists every gateway model and
   lets you fuzzy-filter (`/m-kim` → Kimi entries only).
4. Selecting an entry prints a one-liner telling you exactly what `/model <id>`
   to paste, and persists the choice to `~/.claude/settings.json` so the **next**
   session starts on it by default.

**Why "print and paste" instead of switching automatically?** Slash-command
bodies are sent to the model as text — Claude Code does not re-evaluate a `/`
at the start of them. `/model` has to be typed (or pasted) by the user. Two
keystrokes of fuzzy-match to surface the id, then one paste to activate.

## Files

| File                | Purpose                                                |
|---------------------|--------------------------------------------------------|
| `SKILL.md`          | This doc.                                              |
| `install.sh`        | Registers SessionStart hook, injects config, runs sync.|
| `uninstall.sh`      | Reverses install and deletes generated command files.  |
| `sync.sh`           | Hook body: fetches `/v1/models`, rewrites `m-*.md`.    |

## Manual re-sync

Models added on the gateway after your session started won't appear until next
session. To refresh mid-session:

```bash
bash ~/.claude/hooks/pick-model-sync.sh
```

New `/m-*` entries show up on the next `/` keystroke (Claude Code rescans the
commands dir live).

## Uninstall

```bash
curl -fsSL "$GATEWAY_ORIGIN/api/skills/uninstall.sh?slug=pick-model" | bash
```

This removes the SessionStart hook registration, deletes the hook script, and
wipes `~/.claude/commands/m-*.md`.
