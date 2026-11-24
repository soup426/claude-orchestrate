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
bsh() { jq -cn --arg c "$1" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'; }
t block "first change" s30 "edit Edit $P/a.py"
t allow "same change, second stop" s30 "edit Edit $P/a.py"
t block "a newer change blocks again" s30 "edit Edit $P/a.py; edit Edit $P/b.py"
t allow "reviewed after the newer change" s30 "edit Edit $P/a.py; edit Edit $P/b.py; rev"
t block "sed -i on code under ~/Projects" s31 "bsh \"sed -i s/a/b/ $P/a.py\""
t block "redirect into ~/.claude/hooks" s32 "bsh \"printf x > \$HOME/.claude/hooks/g.sh\""
t block "tilde path with tee" s33 "bsh 'echo x | tee ~/Projects/r/c.py'"
t allow "reading code is not a change" s34 "bsh \"cat $P/a.py | grep x > /tmp/out\""
t allow "sed -i on docs" s35 "bsh \"sed -i s/a/b/ $P/README.md\""
t block "agent file edit counts although .md" s36 "edit Edit $HOME/.claude/agents/worker.md"
t allow "CLAUDE.md is not an agent file" s37 "edit Edit $HOME/.claude/CLAUDE.md"
t block "cp into ~/Projects" s39 "bsh \"cp /tmp/x.py $P/x.py\""
t allow "cp out of ~/Projects" s40 "bsh \"cp $P/x.py /tmp/x.py\""
t block "append redirect, no space" s41 "bsh \"echo x >>$P/a.py\""
t allow "reviewed after the change" s38 "edit Edit $P/a.py; rev"
# Bash write forms (quoted targets, fd redirects, prefixes, -t) count; reads do not
k=50
while IFS= read -r c; do k=$((k+1)); t block "write form: $c" "s$k" "bsh $(printf '%q' "$c")"; done <<EOF
echo x > "\$HOME/Projects/x/a.py"
echo x > '$P/a.py'
echo x >> "$P/a.py"
cp /tmp/a ~/Projects/x/a.py 2>&1
cp -t ~/Projects/x /tmp/a
cp --target-directory=$P a
sudo tee $P/a.py < /tmp/x
FOO=1 sed -i s/a/b/ ~/Projects/a.py
if x; then cp a $P/b.py; fi
timeout 5 mv a \${HOME}/Projects/b.py
echo x &> $P/a.log
printf x>$P/a.py
cat <<X > $P/a.py
EOF
while IFS= read -r c; do k=$((k+1)); t allow "read form: $c" "s$k" "bsh $(printf '%q' "$c")"; done <<EOF
cat $P/a.py > /tmp/x
grep '>' $P/a.py
cp $P/a.py /tmp/b
echo "x > $P/a.py"
ls $P 2>&1 | head
git -C $P diff > /tmp/d
grep -c ";" $P/a.py
EOF
echo "review-stop-gate cases=$n fails=$fails"; [ "$fails" -eq 0 ]
