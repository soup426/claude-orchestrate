#!/usr/bin/env bash
# PreToolUse hook (Edit|Write) for the MAIN session: the third distinct file edited inside a git repo (or under
# ~/Projects, repo or not) without the orchestrate skill is refused once, so a multi-file job gets routed through
# orchestrate. A retry is allowed, so the gate can never lock a session (same one-shot design as agent-report-gate.sh).
# It is a nudge, so every error or missing input allows the edit. Skipped: subagents, files outside a git repo that
# are not under ~/Projects, and anything under ~/.claude, ~/.local/state, /tmp, /var/tmp.
in=$(cat)
[ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && exit 0
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null); tp=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
f=$(jq -r '.tool_input.file_path // empty' <<<"$in" 2>/dev/null | tr -d '\n')
[ -z "$sid" ] || [ -z "$f" ] && exit 0
case $sid in *[!A-Za-z0-9_-]*) exit 0 ;; esac   # session ids are UUIDs; anything else never reaches a file name
case $f in "$HOME"/.claude/*|"$HOME"/.local/state/*|/tmp/*|/var/tmp/*) exit 0 ;; esac
d=$(dirname "$f"); while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1 || case $f in "$HOME"/Projects/*) ;; *) exit 0 ;; esac   # a new project before git init still counts

st=$HOME/.local/state/orchestrate
mkdir -p "$st" 2>/dev/null || exit 0
find "$st" -maxdepth 1 -name 'edit-gate-*' -mtime +1 -delete 2>/dev/null
list=$st/edit-gate-$sid; mark=$st/edit-gate-$sid.refused
command grep -qxF -- "$f" "$list" 2>/dev/null || printf '%s\n' "$f" >> "$list" 2>/dev/null || exit 0
n=$(wc -l < "$list")
[ "$n" -lt 3 ] || [ -e "$mark" ] && exit 0
# Only now read the transcript (it can be large). No transcript: allow. Loaded = a Skill tool call, or the
# /orchestrate command's own message; both are unescaped JSON, so a quoted mention in a file or tool output cannot match.
[ -n "$tp" ] && [ -f "$tp" ] || exit 0
command grep -qE '"skill": ?"orchestrate"|"content": ?"<command-message>orchestrate</command-message>' "$tp" && exit 0
: > "$mark" 2>/dev/null || exit 0   # cannot record the refusal: never refuse (no lockout)
jq -n --arg r "orchestrate-edit-gate: this session is editing a 3rd file in a git repo or under ~/Projects ($n distinct) without the orchestrate skill. If the work splits into 2 or more independent changes, invoke orchestrate now (Skill tool) and plan it there. If it is one module, retry; you still owe superpowers:test-driven-development, one reviewer agent before you call it done or deploy it, and the security agent if it touches secrets, auth, network or untrusted input. This gate refuses only once per session." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
