#!/usr/bin/env bash
# subagent-heartbeat-nudge — keeps babysitting of delegated work on the
# self-stopping heartbeat (CLAUDE.md "Babysitting delegated work").
#
# PostToolUse(Agent|Task|Workflow|delegate_task): when the MAIN agent launches
# background work and no heartbeat is armed for this session, inject a
# one-line reminder to arm one. Silent when:
#   - the call came from a subagent (payload has agent_id) — only the main
#     agent talks to the user;
#   - the Agent call ran in the foreground (run_in_background: false) or a
#     delegate_task ran with mode "sync" — it already finished;
#   - ~/.claude/heartbeat/<session_id>.pid names a live process (the
#     `bin/subagent-status.sh --wait` sleeper is already armed).
#
# PreToolUse(CronCreate|ScheduleWakeup): deny a timer whose prompt is about
# watching subagents/workflows. A recurring CronCreate keeps firing for up to
# 7 days after the work is done — the "status every 5 min about nothing" bug
# seen in 7 of 10 sessions that babysat this way (2026-10). CI/GitHub Actions
# "workflow" timers are left alone.
#
# Self-contained: the reminder carries the babysitting rules, and
# bin/subagent-status.sh's VERDICT line carries the stop rule, so this works
# without the CLAUDE.md block. The script is found relative to this file
# (hooks/ and bin/ are siblings), through any symlinks.
# Fail-open: any parse error exits 0 with no output.
PAYLOAD=$(cat 2>/dev/null) || exit 0
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
STATUS_SCRIPT=$(readlink -f "$HERE/../bin/subagent-status.sh" 2>/dev/null) || STATUS_SCRIPT="$HERE/../bin/subagent-status.sh"
export PAYLOAD STATUS_SCRIPT
python3 - <<'PYEOF'
import json, os, re, sys

try:
    p = json.loads(os.environ.get("PAYLOAD", ""))
except Exception:
    sys.exit(0)
tool = p.get("tool_name", "")
inp = p.get("tool_input") or {}
script = os.environ.get("STATUS_SCRIPT", "")
home = os.path.expanduser("~")
if script.startswith(home + "/"):
    script = "~" + script[len(home):]
HEARTBEAT = f"bash {script} --wait 300"

if p.get("hook_event_name") == "PreToolUse" or tool in ("CronCreate", "ScheduleWakeup"):
    if tool not in ("CronCreate", "ScheduleWakeup"):
        sys.exit(0)
    text = " ".join(str(inp.get(k, "")) for k in ("prompt", "reason"))
    about_agents = re.search(r"\bsub-?agents?\b|\bworkflows?\b|\bwf_[0-9a-f]{6}|background (agent|task)s?|"
                             r"delegate(d|_task)|model-runner|\btask_status\b", text, re.I)
    about_ci = re.search(r"github|\bgh (run|pr)\b|\bCI\b|actions", text, re.I)
    if about_agents and not about_ci:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "Don't babysit delegated work with a timer — recurring crons keep firing after the work is done. "
                f"Use the self-stopping heartbeat instead: Bash run_in_background:true `{HEARTBEAT}`; "
                "re-arm only when its last line says VERDICT: RE-ARM."
            ),
        }}))
    sys.exit(0)

if p.get("agent_id"):
    sys.exit(0)
if tool in ("Agent", "Task") and inp.get("run_in_background") is False:
    sys.exit(0)
if tool.endswith("delegate_task") and inp.get("mode") == "sync":
    sys.exit(0)
sid = p.get("session_id", "")
try:
    pid = int(open(os.path.expanduser(f"~/.claude/heartbeat/{sid}.pid")).read().strip())
    os.kill(pid, 0)
    sys.exit(0)
except (OSError, ValueError):
    pass

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": (
        "Background work launched and no heartbeat is armed for this session. Babysit it: "
        f"(1) now run Bash with run_in_background:true: `{HEARTBEAT}` (one at a time; never a cron/ScheduleWakeup/loop). "
        "It wakes you after 5 min, or ~1 min after all work finishes, with a status report. "
        "(2) On each wake also check task_status for any T3 delegate_task ids. "
        "(3) An errored or STALE subagent: TaskStop it and relaunch once with the same prompt; a STALE workflow: stop it "
        "and resume with resumeFromRunId; never retry an auth/quota failure (model-run.sh exit 75); a second failure: tell the user. "
        "(4) Report 2-4 lines to the user after every check: running and for how long, finished, restarted or stuck, next. "
        "(5) Re-arm ONLY if the report's last line says VERDICT: RE-ARM."
    ),
}}))
PYEOF
exit 0
