#!/usr/bin/env bash
# Tests for scripts/check_drift.sh. Usage: bash tests/test_drift.sh
R=$(cd "$(dirname "$0")/.." && pwd); D=$R/scripts/check_drift.sh
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export HOME=$W/home; unset CLAUDE_DIR; C=$HOME/.claude; mkdir -p "$C/hooks" "$C/agents" "$C/skills"
cp "$R"/hooks/*.sh "$R"/hooks/*.py "$C/hooks/"; cp "$R"/agents/*.md "$C/agents/"; cp -r "$R"/skills/* "$C/skills/"
n=0 fails=0
t() { n=$((n+1)); out=$(bash "$D" "${@:3}" 2>&1); rc=$?; [ "$rc" = "$1" ] || { echo "WRONG want rc=$1 got $rc: $2 ($out)"; fails=$((fails+1)); }; }
t 0 "a fresh install matches"
t 0 "a fresh install matches (quiet)" --quiet
sed -i 's#\$HOME/.local/state#'"$HOME"'/.local/state#' "$C/hooks/agent-report-gate.sh"
t 0 "\$HOME written out as a literal path still matches"
echo '# local tweak' >> "$C/hooks/inspector_guard.py"
t 1 "a changed hook is drift"
n=$((n+1)); bash "$D" --quiet 2>&1 | grep -q 'hook differs: inspector_guard.py' || { echo "WRONG: the drifted hook is not named"; fails=$((fails+1)); }
cp "$R/hooks/inspector_guard.py" "$C/hooks/"; rm "$C/hooks/review-stop-gate.sh"
t 1 "a missing hook is drift"
cp "$R/hooks/review-stop-gate.sh" "$C/hooks/"; echo 'private note' >> "$C/agents/worker.md"
t 0 "an agent that differs is reported, not an error"
n=$((n+1)); bash "$D" 2>&1 | grep -q 'agent differs: worker.md' || { echo "WRONG: the differing agent is not reported"; fails=$((fails+1)); }
n=$((n+1)); [ -z "$(bash "$D" --quiet 2>&1)" ] || { echo "WRONG: --quiet should print nothing when only agents differ"; fails=$((fails+1)); }
H2=$W/a#b.c*; mkdir -p "$H2/.claude"; cp -r "$C"/hooks "$C"/agents "$C"/skills "$H2/.claude/"; cp "$R/hooks/agent-report-gate.sh" "$H2/.claude/hooks/"; sed -i 's|\$HOME/.local/state|'"$H2"'/.local/state|' "$H2/.claude/hooks/agent-report-gate.sh"; cp "$R/agents/worker.md" "$H2/.claude/agents/"
n=$((n+1)); HOME=$H2 bash "$D" --quiet >/dev/null 2>&1 || { echo "WRONG: a home path with # and * should match literally"; fails=$((fails+1)); }
echo '# tweak' >> "$H2/.claude/hooks/inspector_guard.py"
n=$((n+1)); HOME=$H2 bash "$D" --quiet 2>&1 | grep -q 'hook differs: inspector_guard.py' || { echo "WRONG: under a home path with # and *, a changed hook must still be drift"; fails=$((fails+1)); }
echo "drift cases=$n fails=$fails"; [ "$fails" -eq 0 ]
