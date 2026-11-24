#!/usr/bin/env bash
# Stop hook for the MAIN session: if code under ~/Projects, ~/.claude/hooks or ~/.claude/agents was changed after the
# last `reviewer` Agent call, block the stop and say what is owed. Changes are Edit/Write/MultiEdit/NotebookEdit calls
# and Bash commands that name such a path with a write (`sed -i`, `>`, `tee`, `cp`, `mv`). A nudge: it blocks again only
# when a newer change appears than the one it last blocked on, never on a re-stop (stop_hook_active), and every error
# or missing input lets the session stop. Docs (.md, .txt) do not count.
# shortcut: Bash writes through relative paths or variables are not seen; upgrade if a real run slips through.
in=$(cat)
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = true ] && exit 0
[ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && exit 0
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null); tp=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
[ -n "$sid" ] && [ -n "$tp" ] && [ -f "$tp" ] || exit 0
case $sid in *[!A-Za-z0-9_-]*) exit 0 ;; esac
st=$HOME/.local/state/orchestrate; mark=$st/review-stop-$sid.blocked
owed=$(python3 -I "$(dirname "$0")/review_owed.py" "$tp" "$HOME" 2>/dev/null)
case $owed in ''|no|*[!0-9]*) exit 0 ;; esac
prev=$(cat "$mark" 2>/dev/null); case $prev in ''|*[!0-9]*) prev=-1 ;; esac
[ "$owed" -gt "$prev" ] || exit 0   # already blocked on this change
mkdir -p "$st" 2>/dev/null && printf '%s\n' "$owed" > "$mark" 2>/dev/null || exit 0   # cannot record the block: never block (no lockout)
find "$st" -maxdepth 1 -name 'review-stop-*' -mtime +1 -delete 2>/dev/null
jq -n --arg r "review-stop-gate: code under ~/Projects was edited after the last reviewer run. Before you stop: run one reviewer agent on it (plus the security agent if it touches secrets, auth, network or untrusted input), or say in one line why the change is trivial. This gate blocks again only after a newer change." \
  '{decision:"block",reason:$r}'
