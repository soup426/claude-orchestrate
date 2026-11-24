#!/usr/bin/env bash
# PreToolUse hook (Bash) for the MAIN session: a run_in_background command that does not contain "systemd-run" is
# refused once per session, so a long scan, batch job, build or test run gets the memory cap. A retry is allowed, so
# the gate can never lock a session (same one-shot design as orchestrate-edit-gate.sh). It is a nudge, so every error
# or missing input allows the command. Plain substring check, no shell parsing. Skipped: subagents (their own guard
# hook covers them), foreground commands, a bare `sleep N`, `while`/`until ... do sleep` wait loops, estate-warm and ssh.
# Second check, every time and foreground too: ssh fed from stdin that is not a file under ~/Projects makes Claude
# Code ask the user first (see below).
in=$(cat)
[ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && exit 0
cmd=$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null)
# Ask whenever ssh is fed from stdin (a < redirect, a pipe into ssh, a here-doc or here-string), unless every < source
# resolves to a regular file under ~/Projects (in a repo a reviewer can see). realpath catches `..` and symlinks.
host_src=$(python3 -I -c '
import os, re, sys
c, home = sys.argv[1], sys.argv[2]
if not re.search(r"(^|[^A-Za-z0-9_.-])ssh([^A-Za-z0-9_-]|$)", c):
    sys.exit()
bad = []
last = [m.start() for m in re.finditer(r"(^|[^A-Za-z0-9_.-])ssh([^A-Za-z0-9_-]|$)", c)][-1]
if re.search(r"<<|<&|<>|<\(", c) or re.search(r"(?<!\|)\|(?!\|)", c[:last]):   # a pipe (not ||) before any ssh
    bad.append("a pipe, here-doc, here-string, fd or process substitution")
for m in re.finditer(r"[0-9]*<(?![<&>(])\s*([^\s;&|<>()]+)", c):
    src = os.path.expanduser(m.group(1))
    real = os.path.realpath(src)
    if not (os.path.isfile(real) and real.startswith(os.path.realpath(home + "/Projects") + "/")):
        bad.append(m.group(1))
print(", ".join(bad))' "$cmd" "$HOME" 2>/dev/null)
if [ -n "$host_src" ]; then
  jq -n --arg r "main-bash-host-script: ssh is fed from ${host_src}, which no reviewer has seen. Scripts that run on hosts belong in the repo (for example under deploy/), committed and inside the reviewer's commit range; pipe them from there." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
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
mark=$st/bash-cap-gate-$sid.refused
[ -e "$mark" ] && exit 0
: > "$mark" 2>/dev/null || exit 0   # cannot record the refusal: never refuse (no lockout)
jq -n --arg r "main-bash-cap-gate: a background command outside the memory cap. If it is a scan, batch job, build or test run, run it as systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c '...'; if it is light (a watcher, a sleep, a server you will stop), retry; this gate refuses only once per session." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
