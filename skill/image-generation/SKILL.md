---
version: 1.0.2
name: image-generation
description: Generate images via the LitellmCTL gateway (any configured image_generation model). Use whenever the user asks for a picture, illustration, icon, banner, logo, photo, diagram, or any other visual.
---

## Execute

Run the bundled entry-point script — it handles auth, model auto-discovery,
error reporting, and base64 decoding for you. Do **not** try to `bash SKILL.md`
(markdown frontmatter is not valid shell).

```bash
# Required:  PROMPT
# Optional:  MODEL, N, SIZE, OUT_DIR
PROMPT="A polished red cube centered on a pure white background, studio softbox lighting, 1:1" \
  bash "$SKILL_DIR/run.sh"
```

`$SKILL_DIR` is the absolute path to this skill's directory (shown in the skill
header loaded into the conversation, e.g. `~/.claude/skills/image-generation`).

The script prints one absolute path per generated image, one per line:

```
/tmp/image-1713721234-0.jpg
```

Open the file to view it, or embed it in your reply using `![alt](<path>)`.

## Params (all via env vars)

| Name      | Required | Default                  | Notes |
|-----------|----------|--------------------------|-------|
| `PROMPT`  | yes      | —                        | Full prompt. Include style, subject, composition, lighting, mood when relevant. Newlines / quotes / unicode are safe. |
| `MODEL`   | no       | *auto-discovered*        | Any gateway model with `model_info.mode == "image_generation"`. If unset, the script queries the gateway and picks the first available one for your key. |
| `N`       | no       | `1`                      | 1–4. |
| `SIZE`    | no       | *provider default*       | e.g. `1024x1024`, `1200x630`. Passed through as OpenAI-style `size`. Ignored by providers that don't accept it. |
| `OUT_DIR` | no       | `/tmp`                   | Where generated files are written. Created if missing. |

## Error handling

The script surfaces gateway errors verbatim. If the model you passed isn't
accessible to your key, you'll get a response body **plus** a printed list of
image models that ARE available — retry with one of those as `MODEL`.

Exit codes: `0` success, `2` missing config/prompt, `3` no image models
visible, `4` network failure, `5` gateway HTTP error, `6`/`7`/`8` decoding
problems.

## Discover models manually

```bash
curl -fsS "$GATEWAY_URL/api/models/extended" -H "Authorization: Bearer $API_KEY" \
  | python3 -c "import sys,json; print('\n'.join(m['id'] for m in json.load(sys.stdin).get('models',[]) if m.get('mode')=='image_generation'))"
```

(`$GATEWAY_URL` and `$API_KEY` are injected into `run.sh` at install time, so
you don't need them exported for normal use — only for ad-hoc listing.)

## Example

```bash
PROMPT="A 1:1 minimalist app icon: central glowing crimson core with six off-white nodes orbiting it, connected by crisp lines, deep charcoal background. Flat vector, no text." \
  SIZE=1024x1024 \
  OUT_DIR="$HOME/Desktop" \
  bash "$SKILL_DIR/run.sh"
# → /Users/you/Desktop/image-1713721234-0.jpg
```
