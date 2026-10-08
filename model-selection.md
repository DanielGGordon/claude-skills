# Model Selection — WHICH Model, WHEN

Read this before any delegation (Agent-tool subagent or Workflow `agent()`).
It is the whole decision; how to invoke a non-Claude pick is in
`~/.claude/model-usage.md`. The evidence behind every score and row is in
`~/.claude/model-evidence.md`. Open it only to override a default or re-score.

## Pick by Task

| Task | Route | Effort | Output |
| ---- | ----- | ------ | ------ |
| Mechanical / well-specified coding, tests, refactors, fan-out stages | **`sonnet`** (Sonnet 5.5): first pick | `low`/`medium`, **never `max`** | may run unsupervised |
| Same shape, off Claude quota or in the Codex harness / terminal | `--task-type bulk` → gpt-6.1-sol | medium (table) | judge the diff |
| Extraction, summarization, classification, fast drafts | `--task-type draft` → gpt-6-luna | default | judge it; never open-ended agent work |
| Fast multi-file edits, Cursor-shaped | `--task-type cheap` → composer-2.5 | — | judge it; not terminal-heavy |
| Hard problems, orchestration, reviews & planning | **`opus`** (Opus 5.5) | `high` | — |
| Prose, copy, decks, product judgment, UI polish | **`fable`** (Fable 5.1) or `opus` | `high` | judge a Fable *subagent* |
| Non-Claude second opinion on a review / PR | `--task-type second-review` → gpt-6-astra | high (pin) | judge the findings |
| Computer use / GUI agents, 3D/CAD/scenes, long terminal agents, hard science | gpt-6-astra (by id) | start `low`/`medium` | judge it |
| Recent info (web) | Claude WebSearch, or `--task-type recency` → grok-4.7 | — | require dated citations |
| X / social sentiment | `--task-type x-recency` → grok-4.7-xsearch (pay-per-use) | — | posts are leads, not sources |
| Fable out of quota | `--task-type fable-fallback` → gpt-6-astra, or `opus` | as scoped | **announce it** |

## Scores

1–10, higher is better; `*` = provisional. Cost Efficiency is per completed
task at the effort the route runs at. "AA" = Artificial Analysis Intelligence
Index v4.3.2 score and cost per index task.

| Model | CE | Int | Taste | Rel | AA @ effort | Role here |
| ----- | -- | --- | ----- | --- | ----------- | --------- |
| opus-5.5 | 6* | 10* | 8* | 7* | 54 $1.82 @high · 58 $5.98 @max | `opus`, orchestrator |
| sonnet-5.5 | 9* | 9* | 7* | 7* | 41 $0.59 @med · 47 $1.08 @high · 56 $7.60 @max | `sonnet`, cheap default |
| fable-5.1 | 2 | 9 | 9* | 6* | 53 $7.63 @max | `fable`, taste |
| gpt-6-astra | 6 | 9 | 8 | 6 | 53 $3.26 @max | second-review, fallback |
| gpt-6.1-sol | 10* | 9* | 6* | 5* | 48 $0.21 @med · 50 $0.32 @high | `bulk` |
| gpt-6-luna | 10* | 5* | 4* | 3* | 38 $0.07 @max | `draft` |
| haiku-5.5 | 10* | 6* | 5* | 5* | 38 $0.08 @high · 43 $0.21 @max | `haiku` |
| composer-2.5 | 10 | 6 | 4* | 5* | — | `cheap` |
| grok-4.7 | 10* | 7 | 4* | 5* | 46 @xhigh | `recency`, `x-recency` |
| glm-5.2 | 9 | 7 | 7 | 6* | — | by id |
| gpt-6-sol | 9* | 8 | 6* | 5* | 48 $1.06 @max | legacy |
| gpt-5.6-terra | 8 | 7 | 6 | 5* | 42 $1.40 @max | legacy |
| gpt-5.6-sol | 7 | 8 | 6 | 5 | 47 $1.99 @max | legacy |
| grok-4.6 | 10* | 7* | 4* | 4* | — | legacy |

## Rules

1. **Intelligence > Taste > Cost Efficiency** for anything that ships. These
   are defaults, not limits: escalate when output quality isn't there.
2. **Only Reliability ≥ 7 runs unsupervised** (opus-5.5, sonnet-5.5). Judge
   everything else before it lands, including Astra and a Fable *subagent*.
   Judge the diff, not the model's summary of it. Fable stays fine as
   orchestrator or reviewer, where you read the files yourself.
3. **Exit 75 (auth/quota): stop and tell the user. Never substitute a
   model.** The one sanctioned swap is the Fable-quota fallback. When you use
   it, say so, re-read Astra's output, and keep prose and taste work on
   `opus`.
4. **Never grok or composer as a reviewer. Never Haiku for important work.**
   Treat any model's unsourced version, price or API claim as unverified.
5. **Effort:** `sonnet` `low`/`medium` (at `max` it costs more per task than
   opus); `opus`/`fable` `high`, `xhigh` only when truly needed; `low` for
   simple wrappers. Codex efforts come from the routing table.
6. **Prefer task types to raw ids.** The mapping lives in `bin/routes.tsv`,
   not in your judgment. Non-Claude calls go through the `model-runner`
   agent; a hook blocks raw `codex` / `cursor-agent` runs.
7. Give every delegate success criteria, tools, an output format, constraints
   and non-goals. PR-bound work gets a `second-review` pass. Judge every
   output.

## Staying Current

The daily model scout (`bin/model-scout.sh`, 11:30 UTC) researches new
models and updates `bin/routes.tsv`, this card and `model-evidence.md`. It
live-tests every route and merges its own PR once its gates pass.
`bash ~/dotfiles/claude/tests/routecheck.sh` verifies every route and keeps
this file under 8 KB. Watching: **gpt-6.1-luna** (`draft` moves to it the
day Codex lists it), grok-4.8, gemini-4-argon.
