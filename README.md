# claude-skills

Claude Code skills, subagents and a multi-model routing layer, as used day to day.

This repo is a **published subset** of a private Claude Code config repo. It is
regenerated automatically from an allowlist (one commit per sync), so pull
requests here would be overwritten. Open an issue instead.

## What's here

| Path | What it is |
|---|---|
| `skills/` | Claude Code skills (`SKILL.md` + helpers): TDD, "ship it", spec/ticket writing, diagrams, a Python agent loop (`ralph-v2`), … |
| `agents/` | Subagent definitions, e.g. `model-runner` (runs a prompt on a non-Claude model) |
| `model-selection.md` | **Which** model for which task: the routing card, scores and rules |
| `model-usage.md` | **How** to invoke a chosen model (task types, exit codes, the auth/quota stop rule) |
| `model-evidence.md` | Sources and reasoning behind every score |
| `model-internals.md` | Backend mechanics and how to change a route |
| `bin/routes.tsv`, `bin/model-run.sh` | The route table and the runner every non-Claude call goes through |
| `CODING_AGENTS.md`, `plan-requirements.md` | Conventions given to coding agents and the bar a plan must meet |

Paths inside these files (`~/.claude/…`, `~/dotfiles/claude/…`) refer to the
private repo's layout; adapt them to yours.
