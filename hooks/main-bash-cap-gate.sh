#!/usr/bin/env bash
# PreToolUse hook (Bash) for the MAIN session: a run_in_background command that does not contain "systemd-run" is
# refused once per command, so a long scan, batch job, build or test run gets the memory cap. A retry is allowed, so
# the gate can never lock a session. It is a nudge, so every error
# or missing input allows the command. Plain substring check, no shell parsing. Skipped: subagents (their own guard
# hook covers them), foreground commands, a bare `sleep N`, `while`/`until ... do sleep` wait loops, estate-warm and ssh.
# Second check, every time and foreground too: a host-changing ssh/scp/rsync makes Claude Code ask the user first
# while review is owed.
in=$(cat)
[ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && exit 0
cmd=$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null)
# Host-write check. For an ssh, scp or rsync command that inspector_guard.py does not accept as read-only, Claude Code
# asks the user first when code was changed after the last reviewer run (review_owed.py over the transcript).
# Read-only probes never ask. It does not look at where a script fed to the host comes from: that stays a CLAUDE.md
# rule (host scripts live in the repo, committed), because a text check on the command missed too many spellings.
dir=$(dirname "$0")
if [[ $cmd =~ (^|[^A-Za-z0-9_.-])(ssh|scp|rsync|sftp|ssh-copy-id)([^A-Za-z0-9_-]|$) ]] && ! python3 -I "$dir/inspector_guard.py" "$cmd" >/dev/null 2>&1; then
  why=""
  tp=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    owed=$(python3 -I "$dir/review_owed.py" "$tp" "$HOME" 2>/dev/null)
    case $owed in ''|no|*[!0-9]*) ;; *) why="code was changed after the last reviewer run" ;; esac
  fi
  if [ -n "$why" ]; then
    jq -n --arg r "main-bash-host-write: this command changes a host and $why. Run the reviewer first (host scripts belong in the repo, committed, so it can see them), or approve if this was already reviewed." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    exit 0
  fi
fi
[ "$(jq -r '.tool_input.run_in_background // false' <<<"$in" 2>/dev/null)" = true ] || exit 0
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
[ -z "$sid" ] || [ -z "$cmd" ] && exit 0
case $sid in *[!A-Za-z0-9_-]*) exit 0 ;; esac   # session ids are UUIDs; anything else never reaches a file name
case $cmd in *systemd-run*) exit 0 ;; esac
light=1   # every ;/&&/||/| segment starts with estate-warm or ssh, with no lone & and no newline: no local memory
[[ $cmd == *$'\n'* || $cmd =~ (^|[^&])\&([^&]|$) || $cmd == *'$('* || $cmd == *'`'* || $cmd == *'<('* || $cmd == *'>('* ]] && light=0
while IFS= read -r seg; do [[ $seg =~ ^[[:space:]]*(estate-warm|ssh)([[:space:]]|$) ]] || light=0; done < <(printf '%s\n' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g')
[ "$light" = 1 ] && exit 0
[[ $cmd =~ ^[[:space:]]*sleep[[:space:]]+[0-9.]+[smhd]?[[:space:]]*$ ]] && exit 0   # a bare timer (the orchestrate watchdog) is light
[[ $cmd =~ (^|[;&|[:space:]])(while|until)[[:space:]].*do[[:space:]]+sleep[[:space:]] ]] && exit 0   # so is a wait loop (`x=...; while [ ... ]; do sleep 30; done`)

st=$HOME/.local/state/orchestrate
mkdir -p "$st" 2>/dev/null || exit 0
find "$st" -maxdepth 1 -name 'bash-cap-gate-*' -mtime +1 -delete 2>/dev/null
h=$(printf '%s' "$cmd" | sha256sum | cut -c1-16)   # per command: a retry passes, a different job still gets its nudge
mark=$st/bash-cap-gate-$sid-$h.refused
[ -e "$mark" ] && exit 0
: > "$mark" 2>/dev/null || exit 0   # cannot record the refusal: never refuse (no lockout)
jq -n --arg r "main-bash-cap-gate: a background command outside the memory cap. If it is a scan, batch job, build or test run, run it as systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c '...'; if it is light (a watcher, a sleep, a server you will stop), retry; this gate refuses each command only once." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
