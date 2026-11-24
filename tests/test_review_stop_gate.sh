#!/usr/bin/env bash
# Tests for hooks/review-stop-gate.sh. Usage: bash tests/test_review_stop_gate.sh [hook path]
H=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/review-stop-gate.sh}
W=$(mktemp -d) || exit 2; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
export HOME=$W/home; mkdir -p "$HOME/Projects"
n=0 fails=0
edit() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"%s"}}]}}\n' "$1" "$2"; }
rev()  { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"reviewer"}}]}}\n'; }
t() {  # t <want block|allow> <label> <sid> <transcript-builder> [extra json]
  n=$((n+1)); tp=$W/$3.jsonl; eval "$4" > "$tp"
  out=$(jq -cn --arg s "$3" --arg t "$tp" "{session_id:\$s, transcript_path:\$t} + ${5:-{\}}" | bash "$H" 2>/dev/null); got=allow
  [ "$(jq -r '.decision // empty' <<<"$out" 2>/dev/null)" = block ] && got=block
  [ "$got" = "$1" ] || { echo "WRONG want=$1 got=$got: $2"; fails=$((fails+1)); }
}
P=$HOME/Projects/r
t block "code edited, no reviewer" s1 "edit Edit $P/a.py"
t allow "second stop in the same session" s1 "edit Edit $P/a.py"
t allow "reviewer after the edit" s2 "edit Edit $P/a.py; rev"
t block "edit after the last reviewer" s3 "rev; edit Write $P/b.py"
t allow "docs only" s4 "edit Edit $P/README.md; edit Write $P/notes.txt"
t allow "outside ~/Projects" s5 "edit Edit /etc/x.conf; edit Edit $HOME/.claude/CLAUDE.md"
t allow "no edits at all" s6 "true"
t allow "stop_hook_active (re-stop)" s7 "edit Edit $P/a.py" '{stop_hook_active:true}'
t allow "subagent" s8 "edit Edit $P/a.py" '{agent_id:"x"}'
t allow "missing transcript" s9 "true" '{transcript_path:"/nonexistent"}'
t allow "hostile session id" '..x' "edit Edit $P/a.py"
t allow "malformed transcript line" s10 "echo 'not json'; echo '{'"
n=$((n+1)); out=$(printf 'not json' | bash "$H" 2>/dev/null); [ -z "$out" ] || { echo "WRONG: malformed input should allow"; fails=$((fails+1)); }
ro=$W/ro; mkdir -p "$ro/.local"; chmod 555 "$ro/.local"; n=$((n+1)); tp=$W/s11.jsonl; edit Edit "$ro/Projects/a.py" > "$tp"; mkdir -p "$ro/Projects" 2>/dev/null
out=$(jq -cn --arg t "$tp" '{session_id:"s11", transcript_path:$t}' | HOME=$ro bash "$H" 2>/dev/null); [ -z "$out" ] || { echo "WRONG: unwritable state dir must never block"; fails=$((fails+1)); }
t block "MultiEdit counts" s20 "edit MultiEdit $P/m.py"
nb() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"%s"}}]}}\n' "$1"; }
t block "NotebookEdit counts" s21 "nb $P/n.ipynb"
both() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"reviewer"}},{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$1"; }
t block "edit after a reviewer call in the same message" s22 "both $P/a.py"
echo "review-stop-gate cases=$n fails=$fails"; [ "$fails" -eq 0 ]
