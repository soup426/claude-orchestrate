#!/usr/bin/env bash
# Live smoke run of the installed workflow: one headless Claude Code session on a toy git repo, then a summary of what
# the transcript shows (skills, agents, guard and gate firings). Run it after any change to CLAUDE.md, agents, skills or
# hooks and compare with the previous run. Not part of tests/run.sh: it needs a login and costs a few dollars.
# Usage: scripts/smoke.sh <toy repo> [prompt file]     (default prompt: scripts/smoke-prompt.txt)
# The toy repo must be clean. The run's result is committed on a new branch smoke-<time> and the starting branch is
# checked out again, so the next run starts from the same state. Needs: claude, jq, git, a systemd user session.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${1:?usage: smoke.sh <toy repo> [prompt file]}" && pwd) || exit 2
prompt=${2:-$here/smoke-prompt.txt}
[ -f "$prompt" ] || { echo "no prompt file: $prompt" >&2; exit 2; }
[ -z "$(git -C "$repo" status --porcelain)" ] || { echo "toy repo is not clean: $repo" >&2; exit 2; }
start=$(git -C "$repo" branch --show-current); stamp=$(date +%Y%m%d-%H%M%S)
out=${SMOKE_OUT:-${TMPDIR:-/tmp}/orchestrate-smoke-$stamp}; mkdir -p "$out"
run() {   # $1 = round number, rest = claude arguments
  local n=$1; shift
  systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- \
    bash -c 'cd "$1" && shift && timeout 2400 claude -p "$@"' _ "$repo" "$@" --output-format json \
    --debug-file "$out/debug-$n.log" > "$out/result-$n.json" 2>> "$out/stderr.log"
}
run 1 "$(cat "$prompt")"
sid=$(jq -r '.session_id // empty' "$out/result-1.json")
[ -n "$sid" ] || { echo "no session id; see $out" >&2; exit 1; }
t=$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
calls() { jq -r 'select(.message.content|type=="array")|.message.content[]|select(.type=="tool_use")|[.name,(.input.skill//.input.subagent_type//"")]|@tsv' "$1"; }
# A headless session stops where an interactive one waits for the user's go: answer it, at most twice.
for n in 2 3; do
  calls "$t" | grep -q '^Agent	reviewer' && break
  run "$n" --resume "$sid" go
done
echo "session: $sid   transcript: $t   output: $out"
jq -rs '"turns: \(map(.num_turns)|add)   cost of last invocation: $\(.[-1].total_cost_usd)   invocations: \(length)"' "$out"/result-*.json
echo "wall: $(( $(date +%s) - $(date -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s) ))s"
echo "skills:    $(calls "$t" | awk -F'\t' '$1=="Skill"{print $2}' | tr '\n' ' ')"
echo "agents:    $(calls "$t" | awk -F'\t' '$1=="Agent"{print $2}' | sort | uniq -c | tr -s ' \n' ' ')"
echo "messages:  $(calls "$t" | grep -c '^SendMessage') SendMessage (fix rounds and nudges)"
echo "main-session gate lines: $(grep -oE '(review-stop-gate|main-bash-cap-gate|main-bash-host-write)' "$t" | sort | uniq -c | tr -s ' \n' ' ')"
for f in "${t%.jsonl}"/subagents/*.jsonl; do
  [ -f "$f" ] || continue
  printf '  %-12s guard-denials=%s report-gate=%s sandboxed-calls=%s ponytail-rules=%s\n' "$(jq -r '.agentType // "?"' "${f%.jsonl}.meta.json" 2>/dev/null)" \
    "$(grep -c 'agent-bash-guard (' "$f")" "$(grep -c 'agent-report-gate (' "$f")" "$(grep -c 'bwrap --die-with-parent' "$f")" "$(grep -c 'PONYTAIL MODE ACTIVE' "$f")"
done
grep -oh 'agent-bash-guard ([a-z]*): [^.]\{0,120\}' "${t%.jsonl}"/subagents/*.jsonl 2>/dev/null | sort | uniq -c
echo "final message: $(jq -r '.result' "$out"/result-*.json | tail -n +1 | tail -c 600)"
git -C "$repo" checkout -q -b "smoke-$stamp" && git -C "$repo" add -A && git -C "$repo" commit -q -m "smoke run $stamp" --allow-empty
git -C "$repo" checkout -q "$start" && echo "result committed on branch smoke-$stamp; back on $start"
