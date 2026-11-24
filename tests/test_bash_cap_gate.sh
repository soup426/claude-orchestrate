#!/usr/bin/env bash
# Tests for hooks/main-bash-cap-gate.sh. Usage: bash tests/test_bash_cap_gate.sh [hook path]
H=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/main-bash-cap-gate.sh}
W=$(mktemp -d) || exit 2; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
export HOME=$W/home; mkdir -p "$HOME"
CAP="systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'python3 sweep.py'"
n=0 fails=0
t() {  # t <want allow|deny> <label> <raw json> [HOME for the hook]
  n=$((n+1)); out=$(printf '%s' "$3" | HOME=${4:-$HOME} bash "$H" 2>/dev/null); got=allow
  [ -n "$out" ] && [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ] && got=deny
  [ "$got" = "$1" ] || { echo "WRONG want=$1 got=$got: $2"; fails=$((fails+1)); }
}
j() {  # j <sid> <background: true|false> <command> [agent_id]
  jq -cn --arg s "$1" --argjson b "$2" --arg c "$3" --arg a "${4:-}" \
    '{session_id:$s, tool_input:{command:$c, run_in_background:$b}} + (if $a == "" then {} else {agent_id:$a} end)'
}
# Each allow case uses a session that has not been refused yet, and a deny on the same session afterwards
# proves the allow did not come from (or use up) the one refusal.
t deny  "background uncapped is refused" "$(j s1 true 'python3 sweep.py')"
n=$((n+1)); case $(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null) in
  "main-bash-cap-gate: "*"systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G"*) ;;
  *) echo "WRONG: refusal text does not name the gate and the cap command"; fails=$((fails+1)) ;; esac
t allow "retry is allowed" "$(j s1 true 'python3 sweep.py')"
t allow "another uncapped background command after the one refusal" "$(j s1 true 'sleep 1200')"
t allow "background capped" "$(j s2 true "$CAP")"
t deny  "the capped run did not use up the refusal" "$(j s2 true 'pytest -q')"
t allow "foreground uncapped" "$(j s3 false 'pytest -q')"
t allow "run_in_background absent" '{"session_id":"s3","tool_input":{"command":"pytest -q"}}'
t allow "run_in_background null" '{"session_id":"s3","tool_input":{"command":"pytest -q","run_in_background":null}}'
t deny  "foreground runs did not use up the refusal" "$(j s3 true 'pytest -q')"
t allow "subagent background uncapped (1)" "$(j s4 true 'python3 sweep.py' agent-1)"
t allow "subagent background uncapped (2)" "$(j s4 true 'python3 sweep.py' agent-1)"
t deny  "the subagent skip did not use up the refusal" "$(j s4 true 'python3 sweep.py')"
t allow "other session unaffected by s1's marker: capped" "$(j s5 true "$CAP")"
t allow "malformed JSON" 'not json {'
t allow "empty input" ''
t allow "no tool_input" '{"session_id":"s6"}'
t allow "no command" '{"session_id":"s6","tool_input":{"run_in_background":true}}'
t allow "no session id" '{"tool_input":{"command":"python3 sweep.py","run_in_background":true}}'
for c in 'sleep 1200' '  sleep 60' 'until test -e /x; do sleep 5; done'; do t allow "timer or wait loop: $c" "$(j s7 true "$c")"; done
t deny  "sleep followed by a real job is not a timer" "$(j s7 true 'sleep 1; python3 sweep.py')"
for c in 'u=backup.service; while [ "$(systemctl --user show $u -p ActiveState --value)" = activating ]; do sleep 30; done; echo done' 'while true; do sleep 10; done'; do t allow "wait loop: ${c:0:30}" "$(j s9 true "$c")"; done
t deny  "wait loops did not use up the refusal" "$(j s9 true 'python3 sweep.py')"
for x in 1 2; do t allow "hostile session id ($x)" "$(j '../x' true 'python3 sweep.py')"; done
ro=$W/ro-home; mkdir -p "$ro/.local"; chmod 555 "$ro/.local"
for x in 1 2; do t allow "unwritable state dir never refuses ($x)" "$(j s7 true 'python3 sweep.py')" "$ro"; done
old=$HOME/.local/state/orchestrate/bash-cap-gate-oldsession.refused; : > "$old"; touch -d '3 days ago' "$old"
t deny  "pruning run" "$(j s8 true 'python3 sweep.py')"
n=$((n+1)); [ -e "$old" ] && { echo "WRONG: stale state file not pruned"; fails=$((fails+1)); }
# estate-warm and ssh are light; a host script from outside ~/Projects (temp file, pipe) makes the hook ask, every time
for c in "estate-warm atlas pve" "ssh -O check host1 && ssh host1 'uptime'"; do t allow "light: $c" "$(j s10 true "$c")"; done
t deny  "light commands did not use up the refusal" "$(j s10 true 'python3 sweep.py')"
ask() { n=$((n+1)); out=$(printf '%s' "$2" | HOME=/work bash "$H" 2>/dev/null); [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = "$1" ] || { echo "WRONG want=$1: $3"; fails=$((fails+1)); }; }
ask ask "$(j s11 false "ssh pve 'pct exec 104 -- bash -s' < /tmp/x/golive.sh")" "temp-file host script asks"
ask ask "$(j s11 false "printf id | ssh pve sh -s")" "piped host script asks"
ask ask "$(j s11 false "ssh pve 'bash -s' < /tmp/y.sh")" "asks every time, not once"
mkdir -p "$W/hp/Projects/r/deploy" && : > "$W/hp/Projects/r/deploy/setup.sh"
n=$((n+1)); out=$(printf '%s' "$(j s11 false "ssh pve 'bash -s' < $W/hp/Projects/r/deploy/setup.sh")" | HOME=$W/hp bash "$H" 2>/dev/null); [ -z "$out" ] || { echo "WRONG: repo script under ~/Projects should pass"; fails=$((fails+1)); }
ask ask "$(j s12 false "ssh pve bash < /tmp/x.sh")" "ssh bash without -s asks"
ask ask "$(j s12 false "cat f | ssh pve")" "pipe into ssh asks"
ask ask "$(j s12 false "ssh pve 'bash -s' < /work/Projects/../../../tmp/evil.sh")" ".. out of ~/Projects asks"
ask ask "$(j s12 false "cat < /work/Projects/a; ssh pve 'bash -s' < /tmp/e")" "every < is checked"
ask ask "$(j s12 false "ssh pve 'bash -s' <<< id")" "here-string asks"
t deny  "estate-warm chained with a job is not light" "$(j s13 true 'estate-warm atlas; python3 sweep.py')"
for x in "ssh pve bash -s 0</tmp/x.sh" "ssh pve bash -s < <(cat /tmp/x.sh)" "exec 3</tmp/x.sh; ssh pve bash -s <&3" "ssh pve <>/tmp/x.sh" "cat x | timeout 60 ssh pve bash" "cat x | env ssh pve" "cat x |& ssh pve" "cat x | { ssh pve bash; }"; do ask ask "$(j s14 false "$x")" "dodge asks: $x"; done
t deny  "a command substitution makes estate-warm not light" "$(j s15 true 'estate-warm $(cargo build)')"
ask ask "$(j s16 false "ssh -O check pve && cat /tmp/x | ssh pve bash -s")" "a pipe before the second ssh asks"
t deny  "per command: first try of a dev server" "$(j s20 true 'npm run dev')"
t allow "per command: the retry passes" "$(j s20 true 'npm run dev')"
t deny  "per command: a different job still gets its nudge" "$(j s20 true 'python3 sweep.py')"
# host-write check: read-only probes never ask; review owed or an outside source asks
hw() {  # hw <want ask|none> <label> <command> [transcript] [cwd]
  n=$((n+1)); out=$(printf '%s' "$3" | jq -Rsc --arg t "${4:-}" --arg d "${5:-}" '{session_id:"hw",tool_input:{command:.,run_in_background:false},transcript_path:$t,cwd:$d}' | HOME=$W/hp bash "$H" 2>/dev/null)
  got=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"${out:-{\}}" 2>/dev/null); [ "$got" = "$1" ] || { echo "WRONG want=$1 got=$got: $2"; fails=$((fails+1)); }
}
TE=$W/edited.jsonl; TR=$W/reviewed.jsonl
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$W/hp/Projects/r/deploy/setup.sh" > "$TE"
cp "$TE" "$TR"; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"reviewer"}}]}}\n' >> "$TR"
hw none "read-only pipeline after a probe" "ssh -O check h && ssh h 'journalctl -n 5' | grep x"
hw none "a local pipe before a read-only probe" "ls | head; ssh h uptime"
hw none "read-only probe while review is owed" "ssh h uptime" "$TE"
hw ask  "host change while review is owed" "ssh pve 'systemctl restart app'" "$TE"
hw none "host change after the reviewer ran" "ssh pve 'systemctl restart app'" "$TR"
hw none "host change, no transcript" "ssh pve 'systemctl restart app'"
hw ask  "repo script, but edited after the review" "ssh pve bash -s < $W/hp/Projects/r/deploy/setup.sh" "$TE"
hw none "repo script, reviewed" "ssh pve bash -s < $W/hp/Projects/r/deploy/setup.sh" "$TR"
hw none "relative repo script resolves against cwd" "ssh pve bash -s < deploy/setup.sh" "$TR" "$W/hp/Projects/r"
hw ask  "relative path outside the repo" "ssh pve bash -s < ../../../x.sh" "$TR" "$W/hp/Projects/r"
hw ask  "scp from a temp dir" "scp /tmp/x.sh pve:/root/"
hw none "scp from the repo, reviewed" "scp $W/hp/Projects/r/deploy/setup.sh pve:/root/" "$TR"
hw none "scp from the host to here" "scp pve:/etc/x /tmp/x"
hw ask  "rsync from a temp dir" "rsync -a /tmp/site/ pve:/srv/"
hw ask  "scp while review is owed" "scp $W/hp/Projects/r/deploy/setup.sh pve:/root/" "$TE"
hw ask  "scp behind timeout" "timeout 60 scp /tmp/evil.sh pve:/usr/bin/" "$TR"
hw ask  "scp behind env" "env scp /tmp/evil.sh pve:/" "$TR"
hw ask  "scp in a subshell" "(scp /tmp/evil.sh pve:/)" "$TR"
hw ask  "local path with a colon" "scp ./a:b.sh pve:/" "$TR"
hw ask  "absolute path with a colon" "scp /tmp/x:y pve:/" "$TR"
hw ask  "relative source after a cd" "cd /tmp && ssh pve sh < deploy/setup.sh" "$TR" "$W/hp/Projects/r"
hw ask  "ssh-copy-id while review is owed" "ssh-copy-id pve" "$TE"
hw ask  "sftp batch file from a temp dir" "sftp -b /tmp/b pve" "$TR"
big=$(printf 'x%.0s' $(seq 1 140000))
hw ask  "a huge command still asks" "ssh pve 'bash -s' < /tmp/x.sh # $big" "$TR"
pad=$(printf 'scp %.0s' $(seq 1 3000))
hw ask  "thousands of repeated scp words still ask" "$pad /tmp/x pve:/" "$TR"
echo "bash-cap-gate cases=$n fails=$fails"; [ "$fails" -eq 0 ]
