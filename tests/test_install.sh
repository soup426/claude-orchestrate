#!/usr/bin/env bash
# install.sh into a throwaway HOME: installs, refuses to overwrite, backs up with --force, never touches settings.json or CLAUDE.md.
cd "$(dirname "$0")/.." || exit 2
repo=$PWD
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
fails=0
ok() { [ "$1" = 0 ] || { echo "FAIL: $2"; fails=$((fails+1)); }; }
run() { HOME=$H bash "$repo/install.sh" --no-reload "$@" >"$H/out.txt" 2>&1; }

run; ok $? "first install"
for f in agents/worker.md skills/orchestrate/SKILL.md skills/orchestrate/build-config-copies.md hooks/agent-bash-guard.sh orchestrate/write_proposals.py; do
  [ -e "$H/.claude/$f" ] ; ok $? "installed $f"; done
[ -x "$H/.claude/hooks/agent-bash-guard.sh" ]; ok $? "hook is executable"
[ -e "$H/.config/systemd/user/orchestrate.slice" ]; ok $? "slice installed"
[ ! -e "$H/.claude/settings.json" ] && [ ! -e "$H/.claude/CLAUDE.md" ]; ok $? "settings.json and CLAUDE.md untouched"

run; ok $? "re-install of identical files is a no-op"
echo "# local edit" >> "$H/.claude/agents/worker.md"
run; [ $? -ne 0 ]; ok $? "refuses to overwrite a changed file"
command grep -q "local edit" "$H/.claude/agents/worker.md"; ok $? "refused install left the file alone"
run --force; ok $? "--force"
ls "$H/.claude/agents/" | command grep -q 'worker.md.bak-'; ok $? "--force backed the old file up"
! command grep -q "local edit" "$H/.claude/agents/worker.md"; ok $? "--force replaced the file"
echo "install cases done fails=$fails"
[ "$fails" -eq 0 ]
