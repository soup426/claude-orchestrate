#!/usr/bin/env bash
# Tests for deploy/inspector-shell (the forced command) and the local half of deploy/inspector-account.sh.
# The remote half (useradd and file installs as root) is only checked on a real host: see the README, "A read-only account on your hosts".
R=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
n=0 fails=0
ok() { n=$((n+1)); [ "$2" = "$3" ] || { echo "WRONG $1: want [$3] got [$2]"; fails=$((fails+1)); }; }

# The forced command, installed the way the host has it: wrapper and guard side by side.
L=$W/lib; mkdir "$L"; cp "$R/deploy/inspector-shell" "$R/hooks/inspector_guard.py" "$L/"
sh_() { SSH_ORIGINAL_COMMAND=$1 ORCH_TEST_SECRET=s3cret bash "$L/inspector-shell" 2>&1; echo "rc=$?"; }
ok "a read command runs" "$(sh_ 'echo hello')" "hello
rc=0"
ok "a pipeline runs" "$(sh_ 'echo a b | wc -w')" "2
rc=0"
ok "the exit status is the command's" "$(sh_ 'false' | tail -1)" "rc=1"
ok "a write is refused" "$(sh_ "touch $W/made" | tail -1)" "rc=1"
ok "and did not run" "$(ls "$W/made" 2>/dev/null)" ""
ok "command substitution is refused" "$(sh_ 'echo $(id)' | tail -1)" "rc=1"
ok "no command (an interactive login) is refused" "$(SSH_ORIGINAL_COMMAND= bash "$L/inspector-shell" >/dev/null 2>&1; echo $?)" "1"
ok "unset is refused too" "$(env -u SSH_ORIGINAL_COMMAND bash "$L/inspector-shell" >/dev/null 2>&1; echo $?)" "1"
ok "the environment is not passed on" "$(sh_ 'grep -c ORCH_TEST_SECRET /proc/self/environ' | head -1)" "0"
rm "$L/inspector_guard.py"
ok "no guard, no command" "$(sh_ 'echo hello' | tail -1)" "rc=1"

# The local half: a fake ssh records what would be sent.
B=$W/bin; mkdir "$B"
printf '#!/bin/sh\necho "$@" > "%s/args"; cat > "%s/sent.tar"\n' "$W" "$W" > "$B/ssh"; chmod +x "$B/ssh"
K="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfakefakefakefakefakefakefakefakefakefakefake test"
echo "$K" > "$W/good.pub"
acct() { PATH=$B:$PATH bash "$R/deploy/inspector-account.sh" "$@" >/dev/null 2>&1; echo $?; }
ok "a public key installs" "$(acct install testhost "$W/good.pub")" "0"
mkdir "$W/x"; tar -C "$W/x" -xf "$W/sent.tar" 2>/dev/null
ok "the bundle holds the wrapper, the guard, the key line and the remote script" "$(ls "$W/x" | tr '\n' ' ')" "authorized_keys inspector_guard.py inspector-shell remote.sh "
ok "the key line forces the wrapper and restricts everything else" "$(cat "$W/x/authorized_keys")" "restrict,command=\"/usr/local/lib/orchestrate/inspector-shell\" $K"
ok "the host is the ssh target" "$(grep -c "^-- testhost " "$W/args")" "1"
ok "the remote script parses" "$(sh -n "$W/x/remote.sh" 2>&1; grep -c "install -o root -g root -m 644 .*authorized_keys" "$W/x/remote.sh")" "1"
ok "the remote command parses and keeps the sender's uid off the files" "$(sh -n -c "$(cut -d" " -f3- "$W/args")" 2>&1; grep -c -- "--no-same-owner" "$W/args")" "1"
rm -f "$W/args"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n' > "$W/priv"
ok "a private key is refused" "$(acct install testhost "$W/priv")" "1"
printf '%s\n%s\n' "$K" "$K" > "$W/two.pub"
ok "two keys in one file are refused" "$(acct install testhost "$W/two.pub")" "1"
printf '%s\n%s' "$K" "ssh-ed25519 AAAAEVIL" > "$W/two2.pub"
ok "a second key without a final newline is refused" "$(acct install testhost "$W/two2.pub")" "1"
printf 'command="/bin/sh" ssh-ed25519 AAAA\n%s' "$K" > "$W/two3.pub"
ok "options on a first line are refused" "$(acct install testhost "$W/two3.pub")" "1"
echo 'ssh-ed25519 AAAA" ,command="/bin/sh x' > "$W/inj.pub"
ok "a key that would break out of the options is refused" "$(acct install testhost "$W/inj.pub")" "1"
ok "a host that looks like an option is refused" "$(acct install -oProxyCommand=x "$W/good.pub")" "1"
ok "ssh was not called for any refusal" "$(ls "$W/args" 2>/dev/null)" ""
ok "remove needs no key" "$(acct remove testhost)" "0"
ok "an unknown action is refused" "$(acct purge testhost)" "1"

echo "inspector-account cases=$n fails=$fails"; [ "$fails" -eq 0 ]
