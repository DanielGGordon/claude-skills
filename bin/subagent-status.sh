#!/usr/bin/env bash
# subagent-status — one-screen health report of THIS session's delegated work,
# for the babysitting heartbeat (CLAUDE.md "Babysitting delegated work").
#
#   subagent-status.sh              print the report now
#   subagent-status.sh --wait 600   the heartbeat: run with Bash
#                                   run_in_background:true. Polls every 30s and
#                                   exits after 600s — or EARLY, as soon as no
#                                   work is live for two polls in a row — then
#                                   prints the report. Its exit wakes the main
#                                   agent.
#   options: --session <id>   (default $CLAUDE_CODE_SESSION_ID)
#            --stale-min <n>  (default 10) quiet this long with no tool in
#                             flight = STALE
#            --poll <s>       (default 30) poll interval for --wait
#
# The last line is always a script-decided verdict, so the loop cannot run on
# after the work is over:
#   VERDICT: RE-ARM  — something is live (made progress recently)
#   VERDICT: STOP    — nothing live: all finished, or only STALE/abandoned
#                      items left (STALE never keeps the heartbeat going)
#
# Reads only files Claude Code already writes, plus `ps`:
#   ~/.claude/projects/*/<sid>/subagents/agent-*.jsonl (+ .meta.json)
#   ~/.claude/projects/*/<sid>/subagents/workflows/<wf>/agent-*.jsonl
#   ~/.claude/projects/*/<sid>/workflows/<wf>.json   (written ONLY when a
#       workflow completes — killed/crashed runs never get one)
#   ~/.claude/projects/*/<sid>/workflows/scripts/*-<wf>.js (written at launch)
#   model-run.sh processes (non-Claude model calls) under $CLAUDE_PID
# T3 delegate_task children are invisible here — check them with task_status.
#
# While --wait runs it holds ~/.claude/heartbeat/<sid>.pid, which
# hooks/subagent-heartbeat-nudge.sh reads to stay quiet when a heartbeat is
# already armed. Fail-open: always exits 0.
set -u

WAIT=0; POLL=30; SID="${CLAUDE_CODE_SESSION_ID:-}"; STALE_MIN=10
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="${2:-600}"; shift 2 ;;
    --poll) POLL="${2:-30}"; shift 2 ;;
    --session) SID="${2:-}"; shift 2 ;;
    --stale-min) STALE_MIN="${2:-10}"; shift 2 ;;
    *) echo "usage: subagent-status.sh [--wait SECS] [--poll SECS] [--session ID] [--stale-min N]" >&2; exit 0 ;;
  esac
done
[ -n "$SID" ] || { echo "subagent-status: no session id (\$CLAUDE_CODE_SESSION_ID unset; pass --session)"; echo "VERDICT: STOP"; exit 0; }

SESSION_DIR=$(ls -d "$HOME"/.claude/projects/*/"$SID" 2>/dev/null | head -1)
export SID SESSION_DIR STALE_MIN WAIT SELF_PID=$$ ROOT_PID="${CLAUDE_PID:-}"

report() {  # MODE=check: no output, exit 0 if anything is live, 3 if not
python3 - <<'PYEOF'
import glob, json, os, subprocess, sys, time

now = time.time()
mode = os.environ.get("MODE", "report")
sdir = os.environ.get("SESSION_DIR", "")
stale_s = int(os.environ.get("STALE_MIN", "10")) * 60
ABANDON_S = 3600   # quiet this long = abandoned (killed/crashed): counted, not flagged
PHASE_GAP_S = 180  # an unfinished workflow with no agent in flight is "between phases" this long
# "Recently finished" = since the previous heartbeat (or the last 10 min).
recent_s = max(int(os.environ.get("WAIT", "0")), 600)

def age(sec):
    sec = int(sec)
    return f"{sec}s" if sec < 90 else f"{sec // 60}m" if sec < 5400 else f"{sec // 3600}h{sec % 3600 // 60:02d}m"

def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0

def tail_entries(path):
    """Transcript entries from the last 64 KB, oldest first (attachments dropped)."""
    out = []
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 65536))
            for raw in f.read().splitlines():
                try:
                    e = json.loads(raw)
                except Exception:
                    continue
                if e.get("type") in ("assistant", "user"):
                    out.append(e)
    except Exception:
        pass
    return out

def wf_record(wf):
    return f"{sdir}/workflows/{wf}.json"

running, stale, done = [], [], []
abandoned = older_done = 0
wf_live, wf_last = {}, {}  # wf id -> one of its agents is running / newest activity
for tpath in sorted(glob.glob(f"{sdir}/subagents/agent-*.jsonl") + glob.glob(f"{sdir}/subagents/workflows/*/agent-*.jsonl")):
    try:
        meta = json.load(open(tpath[:-len(".jsonl")] + ".meta.json"))
    except Exception:
        meta = {}
    wf = os.path.basename(os.path.dirname(tpath)) if "/subagents/workflows/" in tpath else ""
    name = meta.get("description") or os.path.basename(tpath)
    kind = meta.get("agentType", "agent") + (f"/{meta['model']}" if meta.get("model") else "")
    label = f"[{wf}] {name}" if wf else name
    quiet = now - mtime(tpath)
    if wf:
        wf_last[wf] = max(wf_last.get(wf, 0), mtime(tpath))
    entries = tail_entries(tpath)
    last = entries[-1] if entries else {}
    last_asst = next((e for e in reversed(entries) if e.get("type") == "assistant"), {})
    msg = last_asst.get("message") or {}
    blocks = msg.get("content") if isinstance(msg.get("content"), list) else []
    tools = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_use"]
    # Finished = a plain end_turn, or (workflow agents) the StructuredOutput call
    # that returns the agent's result has come back, or its workflow completed.
    finished = (last is last_asst and msg.get("stop_reason") == "end_turn") or (
        last is not last_asst and any(t.get("name") == "StructuredOutput" for t in tools)) or (
        wf and os.path.exists(wf_record(wf)))
    if finished:
        if quiet <= recent_s:
            done.append(f"  done     {label} ({kind}) — finished {age(quiet)} ago")
        else:
            older_done += 1
        continue
    if last is not last_asst:
        tools = []  # the tool already returned; the model is generating again
    if tools:
        t = tools[-1]
        inp = t.get("input") or {}
        hint = " ".join(str(inp.get("description") or inp.get("command") or inp.get("file_path") or inp.get("pattern") or "").split())[:70]
        what = f"{t.get('name', '?')}{(': ' + hint) if hint else ''}"
        if t.get("name") in ("Agent", "Task", "Workflow"):
            limit = ABANDON_S  # waiting on its own children; they report separately
        else:
            # A tool may legitimately run silent for its own timeout (model-run.sh
            # calls carry ~640s); only past that + 2 min is it presumed hung.
            limit = max(stale_s, (inp.get("timeout") or 0) / 1000 + 120)
        line = f"{label} ({kind}) — in {what} for {age(quiet)}"
    else:
        limit = stale_s
        line = f"{label} ({kind}) — thinking, last write {age(quiet)} ago"
    if quiet <= limit:
        running.append(line)
        if wf:
            wf_live[wf] = True
    elif quiet <= ABANDON_S:
        stale.append(line)
    else:
        abandoned += 1

# A workflow is launched once its script is saved (the name ends in its run id)
# and finished once its record file exists.
for spath in glob.glob(f"{sdir}/workflows/scripts/*.js"):
    base = os.path.basename(spath)[:-3]
    if "wf_" in base:
        wf = base[base.rfind("wf_"):]
        wf_last[wf] = max(wf_last.get(wf, 0), mtime(spath))
workflows, wf_between = [], 0
for wf in sorted(wf_last):
    rec = wf_record(wf)
    if os.path.exists(rec):
        if now - mtime(rec) <= recent_s:
            try:
                st = json.load(open(rec))
                errs = sum(1 for a in st.get("workflowProgress") or [] if a.get("state") == "error")
                workflows.append(f"  {wf}: {st.get('status', '?')}{f' ({errs} agent errors)' if errs else ''}")
            except Exception:
                workflows.append(f"  {wf}: finished")
        continue
    q = now - wf_last[wf]
    if wf_live.get(wf):
        workflows.append(f"  {wf}: running")
    elif q <= PHASE_GAP_S:
        wf_between += 1
        workflows.append(f"  {wf}: starting / between phases (last activity {age(q)} ago)")
    elif q <= ABANDON_S:
        workflows.append(f"  {wf}: STALE — no agent activity for {age(q)} and no completion record (crashed or killed?)")
    else:
        abandoned += 1

live = len(running) + wf_between
if mode == "check":
    sys.exit(0 if live else 3)

procs = []
root = os.environ.get("ROOT_PID", "")
if root.isdigit():
    try:
        out = subprocess.run(["ps", "-eo", "pid=,ppid=,etimes=,args="], capture_output=True, text=True, timeout=5).stdout
        rows = {}
        for ln in out.splitlines():
            p = ln.split(None, 3)
            if len(p) == 4:
                rows[p[0]] = (p[1], int(p[2]), p[3])
        def under_root(pid):
            for _ in range(64):
                if pid == root:
                    return True
                if pid not in rows:
                    return False
                pid = rows[pid][0]
            return False
        self_pid = os.environ.get("SELF_PID", "")
        seen = set()
        # Every non-Claude call goes through model-run.sh (route-guard denies raw
        # codex/cursor-agent), which forks subshells with identical args — list
        # each invocation once, by its oldest pid.
        for pid, (ppid, et, args) in sorted(rows.items(), key=lambda r: int(r[0])):
            argv = args.split()
            if pid == self_pid or ppid == self_pid or len(argv) < 3 or not argv[1].endswith("model-run.sh"):
                continue
            if args in seen or not under_root(pid):
                continue
            seen.add(args)
            procs.append(f"  model-run.sh {' '.join(argv[2:4])} — up {age(et)} (pid {pid})")
    except Exception:
        pass

stale_wf = sum(1 for w in workflows if ": STALE" in w)
print(f"heartbeat {time.strftime('%H:%M')} — {len(running)} running, {len(stale) + stale_wf} STALE, {len(done)} finished since last check"
      + (f", {len(workflows)} workflow(s)" if workflows else ""))
for s in stale:
    print(f"  STALE    {s}")
for r in running:
    print(f"  running  {r}")
for d in done:
    print(d)
if workflows:
    print(" workflows:")
    print("\n".join(workflows))
if procs:
    print(" external model calls in flight:")
    print("\n".join(procs))
if older_done or abandoned:
    print(f"  ({older_done} finished earlier, {abandoned} abandoned >1h ago — ignored)")
if live:
    print("VERDICT: RE-ARM — work is still running.")
elif stale or stale_wf:
    print("VERDICT: STOP — nothing is making progress. Relaunch each STALE item once (TaskStop it first; "
          "the relaunch re-arms via the hook) or tell the user it is stuck. Do not re-arm for STALE items.")
else:
    print("VERDICT: STOP — all delegated work is finished. Do not re-arm and do not send a separate "
          "status message; fold this into your normal reply.")
PYEOF
}

if [ "$WAIT" -gt 0 ] 2>/dev/null; then
  HB_DIR="$HOME/.claude/heartbeat"
  mkdir -p "$HB_DIR" && echo $$ > "$HB_DIR/$SID.pid"
  trap 'rm -f "$HB_DIR/$SID.pid"' EXIT
  # Exit early only after two idle polls in a row: covers the gap between a
  # launch and its first transcript write, and between workflow phases.
  end=$(( $(date +%s) + WAIT )); idle=0
  while [ "$(date +%s)" -lt "$end" ]; do
    left=$(( end - $(date +%s) ))
    sleep $(( left < POLL ? left : POLL ))
    if MODE=check report; then idle=0; else idle=$((idle + 1)); [ "$idle" -ge 2 ] && break; fi
  done
fi
MODE=report report
exit 0
