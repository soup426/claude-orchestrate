#!/usr/bin/env bash
# Tests for hooks/orchestrate-edit-gate.sh. Usage: bash tests/test_edit_gate.sh [hook path]
H=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/orchestrate-edit-gate.sh}
# The work dir is not under /tmp (the hook skips /tmp); GIT_CEILING_DIRECTORIES keeps git from seeing this repo.
W=$(mktemp -d "$(cd "$(dirname "$0")" && pwd)/.edit-gate-XXXXXX") || exit 2; T=$(mktemp -d) || exit 2; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W" "$T"' EXIT
export HOME=$W/home GIT_CEILING_DIRECTORIES=$W
mkdir -p "$HOME/.claude" "$HOME/.local/state" "$W/repo" "$W/plain"
for g in "$W/repo" "$HOME" "$T"; do git -C "$g" init -q; done   # ~/.claude and /tmp are inside repos: only the skip lets them pass
P=$W/t-plain.jsonl L=$W/t-loaded.jsonl C=$W/t-cmd.jsonl M=$W/t-mention.jsonl R=$W/repo
: > "$P"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"orchestrate"}}]}}\n' > "$L"
printf '{"type":"user","message":{"content":"<command-message>orchestrate</command-message>\\n<command-name>/orchestrate</command-name>"}}\n' > "$C"
printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"printf <command-name>/orchestrate</command-name> and {\\"skill\\":\\"orchestrate\\"} <command-message>orchestrate</command-message>"}]}}\n' > "$M"
n=0 fails=0
t() {  # t <want allow|deny> <label> <raw json> [HOME for the hook]
  n=$((n+1)); out=$(printf '%s' "$3" | HOME=${4:-$HOME} bash "$H" 2>/dev/null); got=allow
  [ -n "$out" ] && [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ] && got=deny
  [ "$got" = "$1" ] || { echo "WRONG want=$1 got=$got: $2"; fails=$((fails+1)); }
}
j() {  # j <sid> <transcript> <file> [agent_id]
  jq -cn --arg s "$1" --arg t "$2" --arg f "$3" --arg a "${4:-}" \
    '{session_id:$s, transcript_path:$t, tool_input:{file_path:$f}} + (if $a == "" then {} else {agent_id:$a} end)'
}
t allow "1st file" "$(j s1 "$P" "$R/a.py")"
t allow "2nd file" "$(j s1 "$P" "$R/b.md")"
t allow "same file again does not count" "$(j s1 "$P" "$R/a.py")"
t deny  "3rd distinct file is refused" "$(j s1 "$P" "$R/c.py")"
t allow "retry of the 3rd is allowed" "$(j s1 "$P" "$R/c.py")"
t allow "4th file after the one refusal" "$(j s1 "$P" "$R/d.py")"
for x in a b c d; do t allow "Skill call loaded: $x" "$(j s2 "$L" "$R/$x.py")"; done
for x in a b c d; do t allow "/orchestrate command loaded: $x" "$(j s3 "$C" "$R/$x.py")"; done
for x in a b; do t allow "mention only ($x)" "$(j s4 "$M" "$R/$x.py")"; done
t deny  "a quoted mention in a tool result does not count as loaded" "$(j s4 "$M" "$R/c.py")"
for x in a b c d; do t allow "subagent: $x" "$(j s5 "$P" "$R/$x.py" agent-1)"; done
for x in a b c d; do t allow "outside a git repo: $x" "$(j s6 "$P" "$W/plain/$x.txt")"; done
for x in a b c d; do t allow "under ~/.claude: $x" "$(j s7 "$P" "$HOME/.claude/$x.md")"; done
for x in a b c d; do t allow "under ~/.local/state: $x" "$(j s8 "$P" "$HOME/.local/state/$x")"; done
for x in a b c d; do t allow "under /tmp: $x" "$(j s9 "$P" "$T/$x.py")"; done
t allow "new file in a new subdir counts (1)" "$(j s10 "$P" "$R/new/dir/x.py")"
t allow "(2)" "$(j s10 "$P" "$R/y.py")"
t deny  "(3) refused" "$(j s10 "$P" "$R/z.py")"
t allow "other session unaffected" "$(j s11 "$P" "$R/a.py")"
for x in a b c d; do t allow "missing transcript never refuses: $x" "$(j s12 "$W/nope.jsonl" "$R/$x.py")"; done
for x in a b c d; do t allow "empty transcript_path never refuses: $x" "$(j s13 "" "$R/$x.py")"; done
for x in a b c d; do t allow "hostile session id: $x" "$(j '../x' "$P" "$R/$x.py")"; done
t allow "malformed JSON" 'not json {'
t allow "empty input" ''
t allow "no file_path" '{"session_id":"s14","tool_input":{}}'
t allow "newline in path is one file (1)" "$(j s15 "$P" "$R/n1.py")"
t allow "newline in path is one file (2)" "$(j s15 "$P" "$(printf '%s\n%s\n%s' "$R/x" "$R/y" "$R/z")")"
ro=$W/ro-home; mkdir -p "$ro/.local"; git -C "$ro" init -q; chmod 555 "$ro/.local"
for x in a b c d; do t allow "unwritable state dir: $x" "$(j s16 "$P" "$ro/$x.py")" "$ro"; done
old=$HOME/.local/state/orchestrate/edit-gate-oldsession; : > "$old"; touch -d '3 days ago' "$old"
t allow "pruning run" "$(j s17 "$P" "$R/a.py")"
n=$((n+1)); [ -e "$old" ] && { echo "WRONG: stale state file not pruned"; fails=$((fails+1)); }
H2=$W/home2; mkdir -p "$H2/Projects/new" "$H2/other"   # a second home that is NOT a git repo ($HOME above is one)
t allow "non-git dir under ~/Projects counts (1)" "$(j s18 "$P" "$H2/Projects/new/a.py")" "$H2"
t allow "(2)" "$(j s18 "$P" "$H2/Projects/new/b.py")" "$H2"
t deny  "(3) refused" "$(j s18 "$P" "$H2/Projects/new/c.py")" "$H2"
t allow "retry of the 3rd is allowed" "$(j s18 "$P" "$H2/Projects/new/c.py")" "$H2"
for x in a b c d; do t allow "non-git dir elsewhere under HOME is skipped: $x" "$(j s19 "$P" "$H2/other/$x.py")" "$H2"; done
echo "edit-gate cases=$n fails=$fails"; [ "$fails" -eq 0 ]
