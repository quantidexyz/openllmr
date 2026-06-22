---
name: claude-context
description: Semantic code search via local embeddings and sqlite-vec
type: mcp
---

## What it does

Registers an MCP server that exposes four tools to Claude Code:

- `index_codebase(path, force?, customExtensions?, ignorePatterns?)` — chunk + embed a codebase and store vectors in the gateway's sqlite-vec DB.
- `search_code(path, query, limit?, extensionFilter?)` — natural-language semantic search across indexed code.
- `clear_index(path)` — drop the collection and local merkle state.
- `get_indexing_status(path)` — progress / completion info.

Index state and source files live on your machine. Chunked text is shipped to the openllm gateway, which embeds it with the host's AWS Bedrock Titan v2 credentials and stores the resulting vectors in Neon + pgvector scoped to your user id. The bundle never calls an embedding endpoint directly — keeps the host-paid model out of the public `/v1/embeddings` surface.

## How it's wired

```bash
GATEWAY_URL=__GATEWAY_URL__
API_KEY=__API_KEY__
```

Embedding model and dimensions are fixed by the gateway (`bedrock/titan-embed-v2` @ 1024-d, host AWS credentials) — not configurable per install.

The MCP server is registered in `~/.claude.json` under top-level `mcpServers.claude-context` (user scope) via `claude mcp add-json -s user`, and runs via `bun run <plugin-src>/src/index.ts`. The `SessionStart` + `UserPromptSubmit` hooks are registered in `~/.claude/settings.json` — they shell out to the plugin's CLI subcommands because Claude Code's hook runner can't speak MCP stdio.

## Environment

| Var | Required | Default |
|---|---|---|
| `LLM_GATEWAY_URL` | yes | — |
| `LLM_GATEWAY_API_KEY` | yes | — |

<!-- TODO: migrate docs to LITELLMCTL_URL / LITELLMCTL_API_KEY without breaking deployments. -->
| `CLAUDE_CONTEXT_STATE_DIR` | no | `~/.claude/plugin-state/claude-context` |
| `EMBEDDING_BATCH_SIZE` | no | `64` |

## Uninstall

```
litellmctl plugins uninstall claude-context
```

Removes the `mcpServers.claude-context` entry from `~/.claude.json`, the SessionStart/UserPromptSubmit hooks from `~/.claude/settings.json`, and the plugin directory under `~/.claude/plugins/`. Local vector data in the gateway DB can be removed with `clear_index` before uninstalling, or left intact.
