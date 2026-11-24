#!/usr/bin/env bash
# Stop hook for the MAIN session: if a code file under ~/Projects was edited (Edit/Write) after the last `reviewer`
# Agent call, block the stop once and say what is owed. A nudge: once per session, never on a re-stop
# (stop_hook_active), and every error or missing input lets the session stop. Docs (.md, .txt) do not count.
in=$(cat)
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = true ] && exit 0
[ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && exit 0
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null); tp=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
[ -n "$sid" ] && [ -n "$tp" ] && [ -f "$tp" ] || exit 0
case $sid in *[!A-Za-z0-9_-]*) exit 0 ;; esac
st=$HOME/.local/state/orchestrate; mark=$st/review-stop-$sid.blocked
[ -e "$mark" ] && exit 0
owed=$(python3 -I - "$tp" "$HOME/Projects/" <<'PY' 2>/dev/null
import json, sys
path, root = sys.argv[1], sys.argv[2]
last_edit = last_review = -1
n = 0   # counts tool calls in order, so two calls in one message keep their order
for line in open(path, errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("isSidechain"):
        continue
    c = e.get("message", {}).get("content")
    if not isinstance(c, list):
        continue
    for b in c:
        if b.get("type") != "tool_use":
            continue
        n += 1
        i = b.get("input") or {}
        f = str(i.get("file_path") or i.get("notebook_path") or "")
        if b.get("name") in ("Edit", "Write", "MultiEdit", "NotebookEdit") and f.startswith(root) \
                and not f.endswith((".md", ".txt")):
            last_edit = n
        if b.get("name") == "Agent" and i.get("subagent_type") == "reviewer":
            last_review = n
print("yes" if last_edit > last_review else "no")
PY
)
[ "$owed" = yes ] || exit 0
mkdir -p "$st" 2>/dev/null && : > "$mark" 2>/dev/null || exit 0   # cannot record the block: never block (no lockout)
find "$st" -maxdepth 1 -name 'review-stop-*' -mtime +1 -delete 2>/dev/null
jq -n --arg r "review-stop-gate: code under ~/Projects was edited after the last reviewer run. Before you stop: run one reviewer agent on it (plus the security agent if it touches secrets, auth, network or untrusted input), or say in one line why the change is trivial. This gate blocks only once per session." \
  '{decision:"block",reason:$r}'
