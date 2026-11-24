#!/usr/bin/env bash
# Tests for hooks/sandbox_wrap.py. They run the rewritten commands for real, so "read-only" is checked in the kernel,
# not by reading the wrapper's text. Usage: bash tests/test_sandbox.sh [path/to/sandbox_wrap.py]
# Needs bubblewrap with user namespaces; without it the suite prints SKIP and passes (CI runners often lack it).
H=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/sandbox_wrap.py}
command -v jq >/dev/null || { echo "jq required"; exit 2; }
bwrap --ro-bind / / true 2>/dev/null || { echo "sandbox: SKIP (bubblewrap cannot create a sandbox here)"; exit 0; }
systemd-run --user --scope --quiet true 2>/dev/null || export ORCHESTRATE_SANDBOX_NO_CAP=1   # no user session: test the sandbox without the cap
fails=0; n=0
uid=$(id -u); proj=sandbox-test-$$; sid=11111111-2222-3333-4444-555555555555
S=/tmp/claude-$uid/$proj/$sid; mkdir -p "$S/scratchpad"
W=$(mktemp -d "$HOME/.sandbox-test-XXXXXX")           # a directory under $HOME that must stay read-only
socks=$W/cm; mkdir -p "$socks"; : > "$socks/master-socket"
export ORCHESTRATE_SSH_SOCKET_DIR=$socks
trap 'rm -rf "$W" "/tmp/claude-$uid/$proj"' EXIT

hook() {   # $1 role ("" = main session), $2 command -> the hook's raw output
  jq -n --arg r "$1" --arg c "$2" --arg s "$sid" --arg t "$HOME/.claude/projects/$proj/$sid.jsonl" \
    '{session_id:$s, transcript_path:$t, tool_name:"Bash", tool_input:{command:$c, timeout:5000}} + (if $r=="" then {} else {agent_id:"a1", agent_type:$r} end)' | python3 -I "$H"
}
wrapped() { hook "$1" "$2" | jq -r '.hookSpecificOutput.updatedInput.command // empty'; }
run() { local w; w=$(wrapped "$1" "$2"); [ -n "$w" ] || { echo "NOT-WRAPPED"; return 99; }; bash -c "$w" 2>&1; }
ok() { n=$((n+1)); if [ "$2" = "$3" ]; then :; else fails=$((fails+1)); echo "WRONG $1: want [$3] got [$2]"; fi; }
has() { n=$((n+1)); case $2 in *"$3"*) ;; *) fails=$((fails+1)); echo "WRONG $1: [$3] not in [${2:0:300}]";; esac; }
hasnt() { n=$((n+1)); case $2 in *"$3"*) fails=$((fails+1)); echo "WRONG $1: [$3] found";; esac; }

# 1. Who is wrapped: only the five read-only roles. The main session, the worker and unknown agents pass untouched.
ok "main session untouched" "$(hook "" "echo hi")" ""
ok "worker untouched" "$(hook worker "echo hi")" ""
ok "unknown agent untouched" "$(hook general-purpose "echo hi")" ""
for r in reviewer security researcher inspector verifier; do
  out=$(hook "$r" "echo hi")
  ok "$r decision" "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" allow
  ok "$r keeps other input fields" "$(jq -r .hookSpecificOutput.updatedInput.timeout <<<"$out")" 5000
  ok "$r runs" "$(run "$r" "echo hi")" hi
done

# 2. Writes: nothing outside the session directory, whatever the spelling.
run reviewer "echo x > $W/a" >/dev/null;                               ok "redirect into home" "$(ls "$W" | tr '\n' ' ')" "cm "
run reviewer "python3 -c \"open('$W/b','w').write('x')\"" >/dev/null;  ok "write from an interpreter" "$(ls "$W" | tr '\n' ' ')" "cm "
run security "touch $W/c; cp /etc/hostname $W/d; mkdir $W/e" >/dev/null; ok "touch, cp, mkdir" "$(ls "$W" | tr '\n' ' ')" "cm "
: > "$W/keep"; run researcher "rm -f $W/keep" >/dev/null;              ok "rm" "$(ls "$W" | tr '\n' ' ')" "cm keep "; rm -f "$W/keep"
git -C "$W" init -q r && echo one > "$W/r/f" && git -C "$W/r" add f && git -C "$W/r" -c user.name=t -c user.email=t@t commit -qm one && echo two > "$W/r/f"
run reviewer "git -C $W/r stash" >/dev/null;                           ok "git stash leaves the tree alone" "$(cat "$W/r/f")" two
has "read-only git works" "$(run reviewer "git -C $W/r status --short; git -C $W/r diff --stat")" " M f"
ok "scratch write works" "$(run reviewer "echo data > $S/scratchpad/out.txt && cat $S/scratchpad/out.txt")" data
ok "scratch write is real" "$(cat "$S/scratchpad/out.txt")" data
ok "/tmp is private" "$(run reviewer "touch /tmp/sandbox-test-$$; echo \$?"; ls /tmp/sandbox-test-$$ 2>/dev/null)" 0

# 3. Quoting and exit codes: the original command arrives unchanged.
c='for i in 1 2; do echo "it'"'"'s $i" | sed '"'"'s/it/IT/'"'"'; done; x="a  b"; echo "$x" `echo tick` $(echo sub)'
ok "quotes, loops, expansions" "$(run reviewer "$c")" "$(bash -c "$c")"
c=$'cat <<\'EOF\'\nline "one" $HOME\nline \'two\'\nEOF'
ok "here-doc" "$(run reviewer "$c")" "$(bash -c "$c")"
run reviewer "exit 3" >/dev/null; ok "exit code" "$?" 3

# 4. Network: off for reviewer and security; shared for researcher, verifier and inspector (its allow-list has curl GET and nc -z).
host_net=$(readlink /proc/self/ns/net)
for r in reviewer security; do n=$((n+1)); [ "$(run "$r" "readlink /proc/self/ns/net")" != "$host_net" ] || { fails=$((fails+1)); echo "WRONG $r: shares the host network"; }; done
for r in researcher inspector verifier; do ok "$r network" "$(run "$r" "readlink /proc/self/ns/net")" "$host_net"; done

# 5. Ways out of a read-only root: the user bus, docker, the ssh agent, devices.
ok "runtime dir is empty" "$(run reviewer 'ls -A "$XDG_RUNTIME_DIR" | wc -l')" 0
ok "no bus, no agent in env" "$(run reviewer 'echo "[$DBUS_SESSION_BUS_ADDRESS][$SSH_AUTH_SOCK]"')" "[][]"
export ORCH_TEST_SECRET=s3cret   # stands in for an API token in the Claude Code process environment
for r in reviewer researcher; do ok "$r: environment is an allowlist" "$(run "$r" 'echo "[$ORCH_TEST_SECRET][$HOME][${PATH:+path}][$PYTHONDONTWRITEBYTECODE]"')" "[][$HOME][path][1]"; done
for r in reviewer researcher; do ok "$r: the secret is not in the sandbox's first process either" "$(run "$r" "tr '\\0' '\\n' < /proc/1/environ | grep -c ORCH_TEST_SECRET")" 0; done
# A master-socket directory inside ~/.ssh (the usual ControlPath): bound back for the ssh roles only, without the keys.
F=$W/fh; mkdir -p "$F/.ssh/cm"; : > "$F/.ssh/config"; : > "$F/.ssh/id_test"; : > "$F/.ssh/cm/sock"
ok "inspector: config and sockets come back, keys do not" "$(HOME=$F ORCHESTRATE_SSH_SOCKET_DIR=$F/.ssh/cm run inspector "ls -A $F/.ssh $F/.ssh/cm" | tr '\n' ' ')" "$F/.ssh: cm config  $F/.ssh/cm: sock "
ok "researcher: nothing comes back" "$(HOME=$F ORCHESTRATE_SSH_SOCKET_DIR=$F/.ssh/cm run researcher "ls -A $F/.ssh | wc -l")" 0
ok "no systemd user manager" "$(run reviewer 'systemd-run --user --scope --quiet true 2>/dev/null; echo $?' | tail -1 | tr -d 0)" "1"
[ -S /run/docker.sock ] && ok "docker socket masked" "$(run reviewer 'test -S /run/docker.sock; echo $?')" 1
# A daemon socket under $HOME: a read-only bind alone would still let connect() through.
python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind('$W/app.sock'); s.listen(1); time.sleep(120)" & spid=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$W/app.sock" ] && break; sleep 0.2; done
conn="python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('$W/app.sock'); print('CONNECTED')\" 2>&1 | tail -1"
ok "the test socket is live" "$(bash -c "$conn")" CONNECTED
for r in reviewer researcher verifier; do hasnt "$r cannot connect to a socket under home" "$(run "$r" "$conn")" CONNECTED; done
kill "$spid" 2>/dev/null; rm -f "$W/app.sock"
if [ -d "$HOME/.ssh" ]; then   # private keys: hidden from every role, the config stays for the roles that may ssh
  for r in reviewer researcher verifier; do ok "$r: ~/.ssh is empty" "$(run "$r" 'ls -A ~/.ssh | wc -l')" 0; done
  ok "inspector: no private keys" "$(run inspector 'ls -A ~/.ssh | grep -c -v -x -e config -e config.d -e known_hosts -e cm')" 0
fi
ok "no serial devices" "$(run reviewer 'ls /dev | grep -c -E "ttyUSB|ttyACM|sd[a-z]|nvme"')" 0

# 6. ssh master sockets: hidden unless the role may ssh, and for the verifier only when the whole command is a probe.
ok "reviewer: sockets hidden" "$(run reviewer "ls -A $socks | wc -l")" 0
ok "researcher: sockets hidden" "$(run researcher "ls -A $socks | wc -l")" 0
ok "verifier, ordinary command: sockets hidden" "$(run verifier "ls -A $socks | wc -l")" 0
ok "inspector: sockets visible" "$(run inspector "ls -A $socks")" master-socket
probe="ssh -O check atlas && ssh -o BatchMode=yes atlas 'cat /etc/hostname'"
hasnt "verifier probe: sockets visible" "$(wrapped verifier "$probe")" "--tmpfs $socks"
has "verifier script: sockets hidden" "$(wrapped verifier "python3 deploy_check.py")" "--tmpfs $socks"
has "verifier write over ssh: sockets hidden" "$(wrapped verifier "ssh atlas 'rm -rf /srv/x'")" "--tmpfs $socks"

# 7. The inspector is still checked whole by inspector_guard.py before anything runs.
out=$(hook inspector "ssh atlas 'systemctl restart nginx'")
ok "inspector write is denied" "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" deny
ok "inspector deny has no rewrite" "$(jq -r '.hookSpecificOutput.updatedInput // "none"' <<<"$out")" none
ok "inspector local write is denied" "$(hook inspector "rm -rf /tmp/x" | jq -r .hookSpecificOutput.permissionDecision)" deny
ok "inspector probe is allowed" "$(hook inspector "$probe" | jq -r .hookSpecificOutput.permissionDecision)" allow

# 8. The cap: every wrapped command runs in the slice.
if [ -z "${ORCHESTRATE_SANDBOX_NO_CAP:-}" ]; then
  has "runs in orchestrate.slice" "$(run reviewer "cat /proc/self/cgroup")" "orchestrate.slice"
  has "cap flags" "$(wrapped reviewer "true")" "MemoryMax="
fi

# 9. Failing closed: a subagent call the hook cannot process is denied, never passed through unwrapped.
ok "broken input is denied" "$(echo '{"agent_id":"a1","agent_type":"reviewer","tool_input":"oops"}' | python3 -I "$H" | jq -r .hookSpecificOutput.permissionDecision)" deny
ok "missing session is denied" "$(echo '{"agent_id":"a1","agent_type":"reviewer","tool_input":{"command":"true"}}' | python3 -I "$H" | jq -r .hookSpecificOutput.permissionDecision)" deny
ok "odd session id is denied" "$(jq -n '{agent_id:"a",agent_type:"reviewer",session_id:"../../x",transcript_path:"/h/.claude/projects/p/x.jsonl",tool_input:{command:"true"}}' | python3 -I "$H" | jq -r .hookSpecificOutput.permissionDecision)" deny
ok "unparseable input for the main session passes" "$(echo 'not json' | python3 -I "$H"; echo "rc=$?")" "rc=0"

echo "sandbox cases=$n fails=$fails"
[ "$fails" -eq 0 ]
