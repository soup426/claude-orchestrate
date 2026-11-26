#!/usr/bin/env bash
# Tests for hooks/credential_gate.py. Usage: bash tests/test_credential_gate.sh [hook path]
# Every token below is made up for the test.
H=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/credential_gate.py}
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
n=0 fails=0
t() {  # t <want allow|deny> <label> <command> [session] [agent_id]
  n=$((n+1))
  out=$(jq -cn --arg c "$3" --arg s "${4:-s$n}" --arg a "${5:-}" '{session_id:$s,tool_input:{command:$c}} + (if $a == "" then {} else {agent_id:$a} end)' | HOME=$W python3 -I "$H" 2>/dev/null)
  got=allow; [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${out:-{\}}" 2>/dev/null)" = deny ] && got=deny
  [ "$got" = "$1" ] || { echo "WRONG want=$1 got=$got: $2"; fails=$((fails+1)); }
}
K=Zq7fakeKey0123456789abcdefWXYZ12
t deny  "literal X-Api-Key header" "curl -s -H 'X-Api-Key: $K' http://h:8989/api/v3/queue"
t deny  "literal bearer token" "curl -sk -H \"Authorization: Bearer $K\" https://h/api"
t deny  "git extraHeader token" "git -c 'http.extraHeader=Authorization: token ${K}abcd1234' push https://h/r.git"
t deny  "Kuma push token in a URL" "curl -s 'http://h:3001/api/push/Fk3pQ9zLm2?status=up&msg=OK'"
t deny  "Discord webhook URL" "curl -d x https://discord.com/api/webhooks/123456789012345678/AbcDef123_ghIJkl456-mnoPQR789stu"
t deny  "n8n webhook token" "curl -X POST https://n8n.h/webhook/9f8e7d6c5b4a3f2e1d0c"
t deny  "in a subagent too" "curl -H 'X-Api-Key: $K' http://h/" "" agent1
t allow "key read from its file" "curl -s -H \"X-Api-Key: \$(cat ~/.config/sonarr/key)\" http://h:8989/api"
t allow "key from a variable" "curl -s -H \"Authorization: Bearer \$TOKEN\" https://h/api"
t allow "placeholder in angle brackets" "curl http://h:3001/api/push/<token>?status=up"
t allow "masked value" "echo 'X-Api-Key: ***'"
t allow "too short to be a token" "curl http://h/api/push/abc123"
t allow "letters only is a word, not a token" "curl https://h/hooks/deployment"
t deny  "no space after the colon, lower case" "curl -H 'authorization:bearer $K' https://h/api"
t deny  "--header form" "curl --header \"X-Api-Key: $K\" https://h/api"
t deny  "JSON body header" "python3 -c 'requests.get(u, headers={\"Authorization\": \"Bearer $K\"})'"
t deny  "upper-case scheme" "curl HTTP://h:3001/api/push/Fk3pQ9zLm2"
t deny  "no scheme, host with a port" "curl localhost:3001/api/push/Fk3pQ9zLm2"
t allow "a digits-only id is not a token" "curl https://h/hooks/1234567890123"
t allow "a git hooks path is not a URL" "ls .git/hooks/pre-commit-v2; cat repo/hooks/push/handler2.py"
t allow "header name followed by a newline" "$(printf 'cat <<EOF\napi_key:\n  name1234567890\nEOF')"
t allow "no command" ""
# once per command: a retry of the same command passes (a fake value in a test is never locked out)
t deny  "first try is refused" "curl -H 'X-Api-Key: $K' http://h/" retry
t allow "the same command retried passes" "curl -H 'X-Api-Key: $K' http://h/" retry
t deny  "a different command is still refused" "curl -H 'X-Api-Key: $K' http://h/other" retry
# the reason names the kind, never the value
n=$((n+1)); out=$(jq -cn --arg c "curl -H 'X-Api-Key: $K' http://h/" '{session_id:"why",tool_input:{command:$c}}' | HOME=$W python3 -I "$H" 2>/dev/null)
r=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"${out:-{\}}")
case $r in *"$K"*|"") echo "WRONG: reason is empty or holds the value"; fails=$((fails+1)) ;; *credential-gate*) ;; *) echo "WRONG: reason does not name the gate"; fails=$((fails+1)) ;; esac
# a long run of host-like characters stays fast (an unanchored host:port pattern went quadratic: 40k chars took 13 s)
# and so do many URL starts with no blank between them (an unbounded path repeat: 100k of http:// took 19 s)
for unit in a 'http://' 'a:1/' 'http://h/push/'; do
  n=$((n+1)); { printf '{"session_id":"big","tool_input":{"command":"'; for _ in $(seq $((200000 / ${#unit}))); do printf '%s' "$unit"; done; printf '"}}'; } > "$W/big.json"
  timeout 2 python3 -I "$H" < "$W/big.json" >/dev/null 2>&1 || { echo "WRONG: a 200k-char run of '$unit' took over 2 s"; fails=$((fails+1)); }
done
# errors allow
n=$((n+1)); out=$(printf 'not json' | HOME=$W python3 -I "$H" 2>/dev/null); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] || { echo "WRONG: bad input must allow silently"; fails=$((fails+1)); }
echo "credential-gate cases=$n fails=$fails"; [ "$fails" -eq 0 ]
