#!/usr/bin/env bash
# Tests for the babysitting heartbeat: bin/subagent-status.sh verdicts against
# fixture sessions (plain subagents and /workflows runs), the --wait early
# exit, and hooks/subagent-heartbeat-nudge.sh (nudge + cron guard).
# Runs under a throwaway $HOME; zero tokens. Usage: bash tests/heartbeat.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
STATUS="$REPO/bin/subagent-status.sh"
HOOK="$REPO/hooks/subagent-heartbeat-nudge.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T"
unset CLAUDE_PID
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; echo "$2" | sed 's/^/      /'; }
expect() {  # name, haystack, needle
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "$2"; fi
}

# Transcript last lines, as Claude Code writes them.
END_TURN='{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}'
THINKING='{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}'
in_tool() { printf '{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"%s","input":{"description":"%s","timeout":%s}}]}}' "$1" "$2" "${3:-0}"; }
STRUCT_CALL='{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"StructuredOutput","input":{}}]}}'

n=0
session() { n=$((n + 1)); SID="s$n"; S="$HOME/.claude/projects/-tmp-proj/$SID"; mkdir -p "$S/subagents"; }
agent() {  # id, age-in-minutes, last line(s)...
  local id=$1 mins=$2; shift 2
  local f="$S/subagents/agent-$id.jsonl"
  printf '%s\n' "$@" > "$f"
  echo "{\"agentType\":\"general-purpose\",\"description\":\"job $id\"}" > "$S/subagents/agent-$id.meta.json"
  touch -d "-$mins minutes" "$f"
}
wf_agent() {  # wf, id, age-in-minutes, last line(s)...
  local wf=$1 id=$2 mins=$3; shift 3
  mkdir -p "$S/subagents/workflows/$wf"
  local f="$S/subagents/workflows/$wf/agent-$id.jsonl"
  printf '%s\n' "$@" > "$f"
  echo "{\"agentType\":\"workflow-subagent\",\"description\":\"wf job $id\"}" > "$S/subagents/workflows/$wf/agent-$id.meta.json"
  touch -d "-$mins minutes" "$f"
}
wf_script() { mkdir -p "$S/workflows/scripts"; touch -d "-$2 minutes" "$S/workflows/scripts/my-flow-$1.js"; }
wf_done()   { mkdir -p "$S/workflows"; echo '{"status":"completed","workflowProgress":[{"state":"done"}]}' > "$S/workflows/$1.json"; }
run() { bash "$STATUS" --session "$SID" "$@"; }

# --- plain subagents ---
session; agent a1 1 "$(in_tool Bash 'run tests' 120000)"
out=$(run); expect "agent in a tool -> RE-ARM" "$out" "VERDICT: RE-ARM"

session; agent a1 2 "$END_TURN"
out=$(run); expect "agent finished -> STOP (finished)" "$out" "VERDICT: STOP — all delegated work is finished"
expect "finished agent listed as done" "$out" "done     job a1"

session; agent a1 20 "$THINKING"
out=$(run); expect "quiet 20m -> STALE listed" "$out" "STALE    job a1"
expect "STALE alone -> STOP, never RE-ARM" "$out" "VERDICT: STOP — nothing is making progress"

session; agent a1 12 "$(in_tool Bash 'model-run.sh x-recency' 640000)"
out=$(run); expect "12m inside a 640s model-run call is still running" "$out" "VERDICT: RE-ARM"

session; agent a1 120 "$THINKING"; agent a2 1 "$END_TURN"
out=$(run); expect "killed agent >1h ago is ignored -> STOP" "$out" "VERDICT: STOP — all delegated work is finished"
expect "abandoned agent counted" "$out" "1 abandoned"

session
out=$(run); expect "no delegated work -> STOP" "$out" "VERDICT: STOP"

# --- /workflows runs ---
session; wf_script wf_aaa111-222 0
out=$(run); expect "workflow just launched, no agents yet -> RE-ARM" "$out" "VERDICT: RE-ARM"

session; wf_script wf_aaa111-222 30; wf_agent wf_aaa111-222 b1 1 "$(in_tool Bash 'build' 300000)"
out=$(run); expect "workflow agent working -> RE-ARM" "$out" "VERDICT: RE-ARM"

session; wf_script wf_aaa111-222 30; wf_agent wf_aaa111-222 b1 1 "$STRUCT_CALL" "$THINKING"
out=$(run); expect "workflow between phases (agent returned 1m ago, no record) -> RE-ARM" "$out" "VERDICT: RE-ARM"
expect "StructuredOutput return counts as agent done" "$out" "done     [wf_aaa111-222] wf job b1"

session; wf_script wf_aaa111-222 30; wf_agent wf_aaa111-222 b1 2 "$STRUCT_CALL" "$THINKING"; wf_done wf_aaa111-222
out=$(run); expect "workflow completed -> STOP" "$out" "VERDICT: STOP — all delegated work is finished"

session; wf_script wf_aaa111-222 40; wf_agent wf_aaa111-222 b1 15 "$STRUCT_CALL" "$THINKING"
out=$(run); expect "workflow silent 15m with no record -> STALE" "$out" "STALE — no agent activity"
expect "stale workflow -> STOP, not RE-ARM" "$out" "VERDICT: STOP — nothing is making progress"

session; wf_script wf_aaa111-222 300; wf_agent wf_aaa111-222 b1 200 "$(in_tool Bash 'x' 0)"
out=$(run); expect "workflow killed hours ago -> ignored, STOP" "$out" "VERDICT: STOP — all delegated work is finished"

# --- --wait: stops early instead of pinging about finished work ---
session; agent a1 1 "$END_TURN"
start=$(date +%s); out=$(run --wait 300 --poll 1); took=$(( $(date +%s) - start ))
if [ "$took" -le 10 ]; then ok "--wait with nothing live exits early (${took}s, not 300s)"; else bad "--wait early exit" "took ${took}s"; fi
expect "early exit prints STOP" "$out" "VERDICT: STOP"
[ ! -e "$HOME/.claude/heartbeat/$SID.pid" ] && ok "pidfile removed after exit" || bad "pidfile removed" "$(ls "$HOME/.claude/heartbeat")"

session; agent a1 0 "$(in_tool Bash 'run tests' 120000)"
( sleep 3; printf '%s\n' "$END_TURN" >> "$S/subagents/agent-a1.jsonl" ) &
start=$(date +%s); out=$(run --wait 300 --poll 1); took=$(( $(date +%s) - start ))
if [ "$took" -ge 3 ] && [ "$took" -le 15 ]; then ok "--wait returns soon after the work finishes (${took}s)"; else bad "--wait finish detection" "took ${took}s"; fi
expect "finish-triggered exit says STOP" "$out" "VERDICT: STOP — all delegated work is finished"

session; agent a1 0 "$(in_tool Bash 'run tests' 120000)"
( for i in 1 2 3 4 5 6; do sleep 1; touch "$S/subagents/agent-a1.jsonl"; done ) &
start=$(date +%s); out=$(run --wait 4 --poll 1); took=$(( $(date +%s) - start ))
expect "--wait runs its full interval while work is live" "$out" "VERDICT: RE-ARM"
wait

# --- hook: nudge ---
hook() { bash "$HOOK" <<<"$1"; }
out=$(hook '{"hook_event_name":"PostToolUse","session_id":"h1","tool_name":"Agent","tool_input":{"prompt":"x"}}')
expect "nudge after a background Agent" "$out" "subagent-status.sh --wait 300"
path=$(grep -oE 'bash [^ `]*subagent-status\.sh' <<<"$out" | head -1 | cut -d' ' -f2)
[ -f "${path/#\~/$HOME}" ] || [ -f "$path" ] && ok "nudge points at the real script ($path)" || bad "nudge script path" "$path"
out=$(hook '{"hook_event_name":"PostToolUse","session_id":"h1","tool_name":"Workflow","tool_input":{}}')
expect "nudge after a Workflow" "$out" "subagent-status.sh --wait 300"
for c in '{"hook_event_name":"PostToolUse","session_id":"h1","tool_name":"Agent","tool_input":{"run_in_background":false}}' \
         '{"hook_event_name":"PostToolUse","session_id":"h1","agent_id":"a1","tool_name":"Workflow","tool_input":{}}' \
         '{"hook_event_name":"PostToolUse","session_id":"h1","tool_name":"mcp__t3-code__delegate_task","tool_input":{"mode":"sync"}}' \
         'not json'; do
  out=$(hook "$c"); [ -z "$out" ] && ok "no nudge: ${c:0:70}" || bad "no nudge: $c" "$out"
done
mkdir -p "$HOME/.claude/heartbeat"; sleep 30 & echo $! > "$HOME/.claude/heartbeat/h1.pid"
out=$(hook '{"hook_event_name":"PostToolUse","session_id":"h1","tool_name":"Agent","tool_input":{}}')
[ -z "$out" ] && ok "no nudge while a heartbeat is armed" || bad "armed -> silent" "$out"
kill %% 2>/dev/null; wait 2>/dev/null

# --- hook: cron guard ---
out=$(hook '{"hook_event_name":"PreToolUse","tool_name":"CronCreate","tool_input":{"cron":"*/5 * * * *","prompt":"Check the subagents have not crashed and report"}}')
expect "deny recurring cron babysitting subagents" "$out" '"permissionDecision": "deny"'
out=$(hook '{"hook_event_name":"PreToolUse","tool_name":"CronCreate","tool_input":{"cron":"*/5 * * * *","prompt":"Check the t3code upstream-sync workflow (run wf_99f60b27-738)"}}')
expect "deny cron watching a /workflows run" "$out" '"permissionDecision": "deny"'
out=$(hook '{"hook_event_name":"PreToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":300,"reason":"check on background agents","prompt":"x"}}')
expect "deny ScheduleWakeup babysitting" "$out" '"permissionDecision": "deny"'
for c in '{"hook_event_name":"PreToolUse","tool_name":"CronCreate","tool_input":{"cron":"57 8 * * *","prompt":"run the smoke test"}}' \
         '{"hook_event_name":"PreToolUse","tool_name":"CronCreate","tool_input":{"cron":"*/5 * * * *","prompt":"check the GitHub Actions workflow for PR 12"}}'; do
  out=$(hook "$c"); [ -z "$out" ] && ok "cron allowed: ${c:60:60}" || bad "cron allowed: $c" "$out"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
