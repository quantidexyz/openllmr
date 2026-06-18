---
version: 1.0.1
name: Claude Code
description: Point Claude Code at OpenLLM — sets ANTHROPIC_BASE_URL + maps Opus/Sonnet/Haiku to ultra/plus/lite.
icon: terminal
config_var: OPENLLM_API_KEY
features: ["Merges into ~/.claude/settings.json (non-destructive — preserves your existing hooks, permissions, model)", "Sets ANTHROPIC_BASE_URL to your OpenLLM gateway", "Maps Opus / Sonnet / Haiku → ultra / plus / lite tier aliases"]
requirements: ["Claude Code CLI installed", "jq OR python3 to merge into an existing settings.json (refuses rather than overwrite if neither is present)"]
---

# Claude Code

Runs once on your machine. The script merges OpenLLM's base URL +
your API key into `~/.claude/settings.json` so the Claude Code CLI
talks to your OpenLLM gateway from then on.
