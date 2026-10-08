# Model Usage — HOW to Invoke Each Model

Once `~/.claude/model-selection.md` has told you which model, this is how to
call it. Backend mechanics, raw-command reconstruction, the xAI API details
and the checklist for changing a route are in `~/.claude/model-internals.md`.

## Non-Claude Models: One Path

**Delegating (the normal case):** spawn the **`model-runner`** agent. Give it a
task type (preferred) or a model id, the prompt (text or a file path), and
optionally a workdir and an effort. It runs `model-run.sh` and returns the
model's output verbatim, prefixed `MODEL: <id> (via model-run.sh)`. It shows
up as a named agent in the progress UI.

**Direct call** (quick inline one-offs, scripts, or when you are the wrapper):

```bash
bash ~/dotfiles/claude/bin/model-run.sh --task-type <type> <promptfile> [workdir]
bash ~/dotfiles/claude/bin/model-run.sh <model-id> <promptfile> [workdir]
bash ~/dotfiles/claude/bin/model-run.sh     # no args: lists every id and task type
```

- **Task types** (`bin/routes.tsv` maps each to an id and sometimes an
  effort): `bulk` · `cheap` · `draft` · `recency` · `x-recency` ·
  `second-review` · `fable-fallback`. The script announces what it resolved
  on stderr: `model-run: --task-type bulk -> gpt-6.1-sol (effort medium)`.
- **Prompts always go via a file.** Missing, empty or >128 KiB files exit 64.
  Put big inputs (diffs, logs) in files inside the workdir and reference them
  by path.
- **Raw `codex exec` / `cursor-agent --print` / xAI `curl` calls are
  blocked** by the `route-guard` hook. Read-only `cursor-agent status`,
  `cursor-agent --list-models` and `codex debug models` are allowed.

### Environment

| Variable | Effect |
| -------- | ------ |
| `MODEL_RUN_EFFORT=<low\|medium\|high\|xhigh\|max>` | Codex reasoning effort for this call. Overrides the task row, then the model row (`gpt-6-astra`, `gpt-6.1-sol` pinned `high`; `bulk` runs `medium`). Any other value exits 64; `ultra` is deliberately not wired in. Ignored, with a warning, on cursor/xai. |
| `MODEL_RUN_TIMEOUT=<secs>` | Default 600. |
| `MODEL_RUN_EPHEMERAL=1` | **Test calls only** (smokes, routecheck, the scout). Codex persists no session. Real delegations stay persisted. |
| `MODEL_RUN_XSEARCH_FROM` / `_TO=YYYY-MM-DD` | `x-recency` only: date window for X search. |

### Exit Codes

| Code | Meaning | What you do |
| ---- | ------- | ----------- |
| `0` | success | judge the output |
| `64` | bad id, task type, effort or prompt file (the message lists valid values) | fix the call; a retired id names its successor |
| `73` | transport error that persisted after one automatic retry | retry later; don't switch models unasked |
| `75` | **auth or quota** (incl. Codex "You've hit your usage limit") | **STOP and surface it to the user verbatim. Never substitute a model.** |
| `124` | timeout | the model-runner retries once at 900 s |

### `x-recency` (grok-4.7 on the direct xAI API, X + web search)

The only route that reads X. It needs `XAI_API_KEY`, from the environment or
`~/.profile`. A missing or rejected key exits 75. Proof that X was searched
is model-run's stderr line `model-run: xai-tools x_search=<n> web_search=<n>
... cost_usd=<n>`, not grok's own claim. It is pay-per-use: about $0.10–$1.25
per research question, depending on how many posts it fetches.

## Claude Models (sonnet / opus / fable / haiku)

Native to Claude Code. No wrapper, and not model-run.sh's job (it rejects
them with exit 64).

| Mechanism | How to select the model |
| --------- | ----------------------- |
| **Agent tool** (subagents) | `model` parameter: `"sonnet"`, `"opus"`, `"fable"`, `"haiku"`; `effort` parameter from Claude Code 2.1.292 |
| **Workflow scripts** | `agent(prompt, { model: 'sonnet', effort: 'medium' })` |
| **No `model`** | inherits the session model, so a Fable session fans out Fable workers unless overridden |

- Aliases on Claude Code ≥ 2.1.284 (Anthropic API): `opus` → **Opus 5.5**
  (`claude-opus-5-5`, Claude Code's default), `sonnet` → **Sonnet 5.5**
  (`claude-sonnet-5-5`), `fable` → **Fable 5.1**, `haiku` → **Haiku 5.5**
  (`claude-haiku-5-5`, needs Claude Code ≥ 2.1.293; Haiku 4.5 before).
  Bedrock, Vertex and Foundry may map some aliases to older models.
- `effort` per call: `'low' | 'medium' | 'high' | 'xhigh' | 'max'`. Defaults:
  Opus 5.5, Sonnet 5.5 and Haiku 5.5 `medium`, Fable 5.1 `high`.
- **Don't route through `claude -p --model …` from Bash.** That nests a
  session with separate context and permissions, and you'd be parsing stdout.
  Keep `claude -p` for genuinely detached background jobs.

### When Fable Is Out of Quota

An Agent or Workflow call with `model: 'fable'` may come back with a usage-limit
or model-unavailable error. Don't silently retry on sonnet. Re-dispatch the
same prompt (same success criteria and output format) through `model-runner`
with `--task-type fable-fallback` (→ gpt-6-astra, outside Claude's quota
pool), or announce a re-dispatch on `opus`. Tell the user which model ran. If
Astra then exits 75, stop and surface it. There is no third hop.

## Verifying Routes

`bash ~/dotfiles/claude/tests/routecheck.sh` live-smokes every route.
`--no-live` runs only the free tiers, in seconds: hook and mock tests, table
consistency, catalog drift, and the size budget for these two files. If a
route fails, fix it in `bin/routes.tsv` (see the checklist in
model-internals.md) or remove it. Never leave a documented route broken.
