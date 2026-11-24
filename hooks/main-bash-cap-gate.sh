#!/usr/bin/env bash
# PreToolUse hook (Bash) for the MAIN session: a run_in_background command that does not contain "systemd-run" is
# refused once per session, so a long scan, batch job, build or test run gets the memory cap. A retry is allowed, so
# the gate can never lock a session (same one-shot design as orchestrate-edit-gate.sh). It is a nudge, so every error
# or missing input allows the command. Plain substring check, no shell parsing. Skipped: subagents (their own guard
# hook covers them), foreground commands, and commands that start with `sleep ` or `until ` (timers, wait loops).
in=$(cat)
[ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && exit 0
[ "$(jq -r '.tool_input.run_in_background // false' <<<"$in" 2>/dev/null)" = true ] || exit 0
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null); cmd=$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null)
[ -z "$sid" ] || [ -z "$cmd" ] && exit 0
case $sid in *[!A-Za-z0-9_-]*) exit 0 ;; esac   # session ids are UUIDs; anything else never reaches a file name
case $cmd in *systemd-run*) exit 0 ;; esac
[[ $cmd =~ ^[[:space:]]*(sleep[[:space:]]+[0-9.]+[smhd]?[[:space:]]*|until[[:space:]].*)$ ]] && exit 0   # a bare timer (the orchestrate watchdog) or a wait loop is light

st=$HOME/.local/state/orchestrate
mkdir -p "$st" 2>/dev/null || exit 0
find "$st" -maxdepth 1 -name 'bash-cap-gate-*' -mtime +1 -delete 2>/dev/null
mark=$st/bash-cap-gate-$sid.refused
[ -e "$mark" ] && exit 0
: > "$mark" 2>/dev/null || exit 0   # cannot record the refusal: never refuse (no lockout)
jq -n --arg r "main-bash-cap-gate: a background command outside the memory cap. If it is a scan, batch job, build or test run, run it as systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c '...'; if it is light (a watcher, a sleep, a server you will stop), retry; this gate refuses only once per session." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
