#!/usr/bin/env bash
# Cases for agent-report-gate.sh: refuses a malformed report once per agent, then always lets it through.
cd "$(dirname "$0")/.." || exit 2
command -v jq >/dev/null || { echo "jq required"; exit 2; }
G=$PWD/hooks/agent-report-gate.sh
export ORCHESTRATE_STATE_DIR; ORCHESTRATE_STATE_DIR=$(mktemp -d); trap 'rm -rf "$ORCHESTRATE_STATE_DIR"' EXIT
fails=0
g() { jq -n --arg id "$1" --arg m "$3" '{agent_id:$id,tool_input:{message:$m}}' | "$G" "$2"; }
check() { # name, expect (deny|allow), output
  got=allow; [ -n "$3" ] && got=deny
  [ "$got" = "$2" ] || { echo "WRONG $1: want=$2 got=$got"; fails=$((fails+1)); }
}
check "good worker report"   allow "$(g a1 worker $'STATUS: DONE\nCHANGED:')"
check "bad worker report"    deny  "$(g a2 worker 'all done')"
check "second try passes"    allow "$(g a2 worker 'still not in format')"
check "reviewer needs verdict" deny "$(g a3 reviewer 'looks fine')"
check "reviewer verdict ok"  allow "$(g a4 reviewer $'VERDICT: PASS')"
check "researcher needs ANSWER" deny "$(g a5 researcher 'FACTS: x')"
check "researcher ok"        allow "$(g a6 researcher $'ANSWER:\n- q: a')"
check "researcher per-question format ok" allow "$(g a7 researcher $'ANSWER:\n### q1\nTakeaway: a\nCited:\n- f (u)\nGaps:\n- none\nVERSIONS: n/a')"
case $(g a8 researcher 'no format') in *Takeaway*Gaps*) ;; *) echo "WRONG researcher refusal names the per-question format"; fails=$((fails+1)) ;; esac
echo "gate cases done fails=$fails"
[ "$fails" -eq 0 ]
