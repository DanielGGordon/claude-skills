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
| `hooks/subagent-heartbeat-nudge.sh`, `bin/subagent-status.sh`, `tests/heartbeat.sh` | Subagent babysitting: a self-stopping 10-minute heartbeat for background subagents and workflows (see below) |
| `CODING_AGENTS.md`, `plan-requirements.md` | Conventions given to coding agents and the bar a plan must meet |

Paths inside these files (`~/.claude/…`, `~/dotfiles/claude/…`) refer to the
private repo's layout; adapt them to yours.

## Subagent babysitting (heartbeat)

When the main agent runs subagents or `/workflows` in the background, you can't
tell whether they're working, stuck, or dead, and asking for "check every 5
min" with `/loop` or a cron keeps pinging long after the work is done. This
replaces that with a heartbeat that stops itself:

- After any background `Agent` / `Workflow` launch, a PostToolUse hook tells
  the agent to start `bin/subagent-status.sh --wait 600` as a background Bash
  command, and lists the rules: report 2–4 lines on every wake, restart a dead
  or stuck subagent once, re-arm only on `VERDICT: RE-ARM`.
- The script reads the session's subagent and workflow transcripts under
  `~/.claude/projects/` and reports each agent's current tool, how long it has
  been quiet, and `STALE` flags. It wakes the agent after 10 min, or about 1 min
  after everything finishes, and the last line is a script-decided
  `VERDICT: RE-ARM` or `VERDICT: STOP`. Stuck or killed work never keeps it
  going.
- A PreToolUse hook denies `CronCreate` / `ScheduleWakeup` timers about
  watching subagents (CI/GitHub workflow timers are allowed).

Setup: keep `hooks/` and `bin/` as siblings, since the hook finds the script
relative to itself. Then register the hook in `~/.claude/settings.json`:

```json
"hooks": {
  "PostToolUse": [{ "matcher": "Agent|Task|Workflow",
    "hooks": [{ "type": "command", "command": "bash /path/to/hooks/subagent-heartbeat-nudge.sh" }] }],
  "PreToolUse": [{ "matcher": "CronCreate|ScheduleWakeup",
    "hooks": [{ "type": "command", "command": "bash /path/to/hooks/subagent-heartbeat-nudge.sh" }] }]
}
```

Needs bash and python3. Linux `ps` and `readlink -f` assumed. `bash tests/heartbeat.sh`
runs the self-tests (no model calls).

