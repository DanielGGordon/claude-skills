# Model Routing Internals — Mechanics, Backends, Maintenance

**Not read before delegating** — `~/.claude/model-selection.md` (which model)
and `~/.claude/model-usage.md` (how to call it) are. This file is for
debugging a route, reconstructing a raw call with Dan's approval, or changing
the routing layer itself. Evidence behind scores lives in
`~/.claude/model-evidence.md`.

## Changing a Route — Everything That Moves Together

`bin/routes.tsv` is the single source of truth for ids, backends, effort pins,
retired ids, task types and ignore rows; `bin/model-run.sh`, routecheck and
catalog-drift all read it. A route change touches, in order:

1. `bin/routes.tsv` — the row(s), with a one- or two-line dated comment.
2. `hooks/route-guard.sh` — the literal `RETIRED` dict, for a retired id (one
   `    "old": "successor",` line each; routecheck checks it equals the table).
3. `tests/mock-catalog.tsv` — every routed cursor/codex id listed `routed`;
   its hypothetical next versions stay ahead of the routed ones.
4. `model-selection.md` — the scores row / task table (one line each), and
   `model-evidence.md` — the dated changelog entry and the model's note with
   sources. Never copy an id list into markdown: `bash bin/model-run.sh` with
   no args prints the live one.
5. `tests/workflows/orchestration-smoke-model-runner.js` (`IDS` / `TASKS`) when
   a task row moves.
6. Run `bash ~/dotfiles/claude/tests/routecheck.sh` (free tiers in seconds with
   `--no-live`; the full run smokes every route).

## Effort

Codex applies each model's **catalog default** reasoning level unless told
otherwise, and for the frontier tiers (`gpt-6-astra`, `gpt-6.1-sol`,
`gpt-5.6-sol`) that default is **`low`** — so effort lives in the table:
the model row's 4th column pins it (astra and 6.1-sol: `high`), a task row's
4th column overrides that for the task (`bulk` → gpt-6.1-sol at `medium`), and
`MODEL_RUN_EFFORT` overrides both for one call. model-run accepts only
`low|medium|high|xhigh|max` (anything else exits 64). Astra's catalog also
lists **`ultra`** ("maximum reasoning with automatic task delegation"): it
lets the model spawn its own delegated sub-tasks — a different cost and
supervision story — so it is deliberately not wired in. The Codex banner
echoes the effort it actually used (`reasoning effort: high`).

## Under the Hood (route-guard blocks running these directly)

What `model-run.sh` executes, kept here so its behavior is auditable and so a
raw invocation can be reconstructed *with the user's explicit approval*:

What `model-run.sh` executes, kept here so its behavior is auditable and so a
raw invocation can be reconstructed *with the user's explicit approval*:

- **Codex:** `codex exec --dangerously-bypass-approvals-and-sandbox -C <workdir> -m <model> [-c model_reasoning_effort="<level>"] [--ephemeral] "$(cat <promptfile>)" </dev/null`
  — `</dev/null` because codex-cli (0.159+) reads stdin whenever it isn't a
  TTY and blocks on an open pipe;
  the bypass flag is required because Codex's bwrap sandbox cannot nest inside
  Claude Code's Bash sandbox (`bwrap: loopback: Failed RTM_NEWADDR`); Claude
  Code's own sandbox remains the outer boundary. Session continuation:
  `codex exec ... resume --last "..."`. With `MODEL_RUN_EPHEMERAL=1` it adds
  `--ephemeral` (no session files / thread rows) — for **test** calls only
  (routecheck, the model scout, the orchestration smoke); real delegations stay
  persisted so their history is useful.
- **Cursor:** `cursor-agent --print --trust --force --output-format text --model <id> "$(cat <promptfile>)"`
  — unknown ids hard-error with the full valid list, but *retired* ids can
  silently remap to a successor (e.g. `composer-2` → 2.5); model-run.sh and
  routecheck exist precisely to catch that class. Check auth with
  `cursor-agent status`; list ids with `cursor-agent --list-models` (both
  allowed by the guard, as is `codex debug models`, the Codex catalog read).
  `bash ~/dotfiles/claude/bin/catalog-drift.sh` diffs those catalogs against
  routes.tsv. The Cursor catalog also exposes OpenAI/Anthropic/Google models —
  route those through their native paths instead (routes.tsv marks such ids
  with `ignore <glob> <reason>` rows so they stop showing as unrouted). Cursor
  has no ephemeral mode: its chats are keyed by cwd (`~/.cursor/chats/<md5(cwd)>`),
  so a test call must use a throwaway `mktemp -d` workdir and then run
  `bin/test-chat-cleanup.sh --since <epoch> --marker <str> --workdir <dir>`.
- **Reviews via Codex:** same path — prompt asks for findings with **severity**,
  **file:line**, a **concrete failing scenario**, and a **SHIP / FIX-FIRST**
  verdict.

> **Cursor TypeScript SDK (`@cursor/sdk`): evaluated 2026-07-21, rejected.** Two
> independent reviews (gpt-5.6-sol, grok-4.5) both concluded STAY-ON-CLI: the CLI
> already covers streaming/resume/model-listing; the SDK would mean a bespoke Node
> wrapper + npm surface in this repo, plain-`string` model ids (no added safety),
> and possible consumption billing vs the already-paid seat. Re-evaluate only if
> the CLI loses capabilities or the SDK gains subscription-seat auth.
>
> **codex-plugin-cc**: evaluated and removed 2026-07-07 — hardcoded per-turn
> sandbox modes incompatible with nested bwrap here.

## Direct xAI API (grok with X search) — `x-recency`

**Wired 2026-09-22.** The only route with **real X (Twitter) search**: grok
via cursor-agent (`--task-type recency`) has web search only. Use it for
social / X sentiment (see model-selection.md "Recent Information"):

```bash
bash ~/dotfiles/claude/bin/model-run.sh --task-type x-recency <promptfile> [workdir]
MODEL_RUN_XSEARCH_FROM=2026-09-15 bash ~/dotfiles/claude/bin/model-run.sh grok-4.7-xsearch <promptfile>
```

- **Backend `xai`** in routes.tsv: `model grok-4.7-xsearch xai grok-4.7`. The
  id is ours, and column 4 is the xAI API model it calls. model-run.sh `curl`s
  `POST https://api.x.ai/v1/responses` with `{"model": "grok-4.7", "input":
  [<prompt>], "tools": [{"type": "web_search"}, {"type": "x_search"}],
  "store": false}`. `store: false` means xAI persists no conversation, so a
  test call leaves nothing behind and needs no cleanup.
  `MODEL_RUN_XSEARCH_FROM` / `MODEL_RUN_XSEARCH_TO` (`YYYY-MM-DD`, inclusive)
  set `x_search`'s `from_date` / `to_date`.
- **Output:** stdout is the answer, then a `Sources:` list of every cited URL
  (the `url_citation` annotations and the response's `citations`). Stderr gets
  exactly one `model-run: xai-tools x_search=<n> web_search=<n> x_posts=<n>
  cited_urls=<n> status=... cost_usd=<n> store=false` line, from the
  response's `usage.server_side_tool_usage_details` and `cost_in_usd_ticks`.
  It is printed only when an answer came back, so `x_search>=1` there is
  proof X was searched. grok's own claims about which tools it used are not
  proof.
- **Key:** `XAI_API_KEY`, taken from the environment, or else from what
  `~/.profile` exports. That is the same source as the scout's cron line
  (`. ~/.profile && ...`), so a Claude Code session that wasn't started from a
  login shell still works. The key is sent as a header read from a
  process-substitution fd. It never appears in argv (`ps`) or on disk. Never
  print it.
- **Exit codes, same contract:** key missing, or rejected (xAI answers a bad
  key with HTTP 400 "Incorrect API key"), 401/403, 402/429 credits or rate
  limit → `75` (STOP and surface: `XAI_API_KEY rejected` / `not set` /
  `credits ... exhausted`). 5xx or no response (including a connect that
  never completes within 20 s) → one retry, then `73`. A response that
  doesn't arrive within `MODEL_RUN_TIMEOUT` → `124`. Other 4xx (e.g. 404 for an API model id
  that no longer exists) → `1`, with xAI's error body.
- **Catalog:** `bash ~/dotfiles/claude/bin/model-run.sh --xai-models` lists
  the API model ids (`GET /v1/models`, zero tokens; exit 69 = no key; 75 =
  key rejected / out of credits; 73 = a plain 429 rate limit or network error,
  which routecheck's `auth:xai` only WARNs on).
  `bin/catalog-drift.sh` uses it to flag a column-4 id that vanished. It
  checks nothing else for xai: new groks surface through the Cursor catalog,
  and without a key the xai check is skipped silently.
- **Guarded:** route-guard denies raw `curl` to `api.x.ai/v1/responses` /
  `chat/completions` (the catalog read `GET /v1/models` is allowed).
- **Cost** (docs.x.ai models and pricing pages, fetched 2026-09-22):
  grok-4.7 is $2 / $6 per Mtok in / out, with cached input $0.50. Past a
  200k-token prompt that becomes $4 / $12 (cached $1). The context window is
  500k. On top of tokens, `web_search` is $5 per 1k calls, and `x_search` is
  billed **per item fetched**: $5 per 1k posts (parent and quoted posts count)
  and $10 per 1k profiles. Two sentiment questions on 2026-09-22 (3 x_search
  calls, 14–18 posts each) cost $0.10 and $0.14 each. routecheck's smoke tells
  grok not to search, and costs under a cent.
- **Quirk:** grok-4.7 on this API refuses "output exactly this line / token"
  prompts ("I won't output exact phrases or tokens on demand": 6 of 7
  attempts, 2026-09-22), so nonce-echo tests don't work on it. routecheck
  asks it for a per-run random sum instead.
- The old Live Search API (`search_parameters`) is dead (HTTP 410). Agent
  Tools on the Responses API are the only search interface.

