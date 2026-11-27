#!/usr/bin/env bash
# Compare an installed ~/.claude against this repo.
# Hooks must match exactly (after the user's home path is written back as $HOME): a hook that differs or is missing
# is drift, and the exit code is 1. Agents and skills are only reported, because an installed copy may carry
# private details on purpose (your own MCP tools, host names in a skill).
# Not compared on purpose: file modes, and installed hooks the repo does not ship (your own private hooks).
# Usage: scripts/check_drift.sh [--quiet]   (--quiet prints only hook drift)
here=$(cd "$(dirname "$0")/.." && pwd)
claude=${CLAUDE_DIR:-$HOME/.claude}
quiet=0; [ "${1:-}" = --quiet ] && quiet=1
# Literal match (no regex), and both sides go through it so trailing-newline handling is the same.
norm() { awk -v h="$HOME" '{o=""; while ((i = index($0, h)) > 0) { o = o substr($0, 1, i-1) "$HOME"; $0 = substr($0, i+length(h)) } print o $0}' "$1"; }
bad=0
for f in "$here"/hooks/*.sh "$here"/hooks/*.py; do
  [ -f "$f" ] || continue
  n=$(basename "$f"); i=$claude/hooks/$n
  if [ ! -f "$i" ]; then echo "hook missing: $n"; bad=1
  elif ! cmp -s <(norm "$i") <(norm "$f"); then echo "hook differs: $n"; bad=1; fi
done
if [ "$quiet" = 0 ]; then
  for f in "$here"/agents/*.md; do
    n=$(basename "$f"); i=$claude/agents/$n
    if [ ! -f "$i" ]; then echo "agent missing: $n"; elif ! cmp -s <(norm "$i") <(norm "$f"); then echo "agent differs: $n"; fi
  done
  for i in "$claude"/agents/*.md; do   # sandbox_wrap.py wraps only the roles it names, so a stray copy runs Bash unsandboxed
    [ -f "$i" ] && [ ! -f "$here/agents/$(basename "$i")" ] && echo "agent not in repo: $(basename "$i") (its Bash is not sandboxed unless hooks/sandbox_wrap.py names it)"
  done
  for f in "$here"/skills/*/*.md; do
    n=$(basename "$(dirname "$f")")/$(basename "$f"); i=$claude/skills/$n
    if [ ! -f "$i" ]; then echo "skill missing: $n"; elif ! cmp -s <(norm "$i") <(norm "$f"); then echo "skill differs: $n"; fi
  done
fi
exit "$bad"
