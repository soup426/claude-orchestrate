#!/usr/bin/env bash
# Install the orchestrate workflow into ~/.claude and ~/.config/systemd/user.
# Usage: ./install.sh [--force] [--no-reload]
#   --force      replace files that differ (the old file is first copied to <name>.bak-<timestamp>)
#   --no-reload  skip `systemctl --user daemon-reload`
# Never edits settings.json or CLAUDE.md: it only prints what to add.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
force=0 reload=1
for a in "$@"; do
  case $a in
    --force) force=1 ;;
    --no-reload) reload=0 ;;
    *) echo "usage: $0 [--force] [--no-reload]" >&2; exit 2 ;;
  esac
done

claude=$HOME/.claude
sysd=$HOME/.config/systemd/user
pairs=()  # "source|destination"
for f in "$here"/agents/*.md; do pairs+=("$f|$claude/agents/$(basename "$f")"); done
for f in "$here"/skills/*/SKILL.md; do pairs+=("$f|$claude/skills/$(basename "$(dirname "$f")")/SKILL.md"); done
for f in "$here"/hooks/*.sh; do pairs+=("$f|$claude/hooks/$(basename "$f")"); done
pairs+=("$here/scripts/write_proposals.py|$claude/orchestrate/write_proposals.py")
pairs+=("$here/systemd/orchestrate.slice|$sysd/orchestrate.slice")

# Pass 1: refuse before writing anything if a different file is already there.
conflicts=()
for p in "${pairs[@]}"; do
  src=${p%%|*} dst=${p#*|}
  if [ -L "$dst" ]; then echo "refusing: $dst is a symlink (remove it or point it elsewhere first)" >&2; exit 1; fi
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then conflicts+=("$dst"); fi
done
if [ ${#conflicts[@]} -gt 0 ] && [ "$force" -eq 0 ]; then
  echo "These files already exist and differ from this repo (nothing was changed):" >&2
  printf '  %s\n' "${conflicts[@]}" >&2
  echo "Re-run with --force to back them up (<name>.bak-<timestamp>) and replace them." >&2
  exit 1
fi

# Pass 2: copy.
stamp=$(date +%Y%m%d-%H%M%S)
for p in "${pairs[@]}"; do
  src=${p%%|*} dst=${p#*|}
  if [ -e "$dst" ]; then
    cmp -s "$src" "$dst" && continue
    cp -p "$dst" "$dst.bak-$stamp"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
  echo "installed $dst"
done

if [ "$reload" -eq 1 ]; then
  systemctl --user daemon-reload || echo "warning: systemctl --user daemon-reload failed; the slice will not exist until it works" >&2
fi
# Private terms for the security agent: install the template once, never overwrite the user's list.
terms="$claude/security/private-terms.txt"
if [ -L "$terms" ]; then echo "warning: $terms is a symlink; not touching it" >&2
elif [ ! -e "$terms" ]; then mkdir -p "$(dirname "$terms")" && install -m 600 "$here/templates/private-terms.txt" "$terms" && echo "installed $terms (add your own private terms)"; fi
command -v jq >/dev/null || echo "warning: jq is not installed; the hooks need it (they fail open without it)" >&2

cat <<MSG

Files installed. Two manual steps remain (this script never edits your settings.json or CLAUDE.md):

1. Add to ~/.claude/CLAUDE.md:
------------------------------------------------------------
$(cat "$here/snippets/CLAUDE.md")
------------------------------------------------------------

2. Merge into ~/.claude/settings.json (keep your other keys):
------------------------------------------------------------
$(cat "$here/snippets/settings.json")
------------------------------------------------------------
Restart Claude Code so it loads the new agents and skills.
MSG
