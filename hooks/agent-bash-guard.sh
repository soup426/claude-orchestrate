#!/usr/bin/env bash
# PreToolUse hook (Bash) for the worker agent, wired in its frontmatter. The read-only agents do not use it: their
# commands run in a sandbox (sandbox_wrap.py). A worker runs arbitrary code by design, so this is a seatbelt for the
# few things workers share, not a boundary: the git tree and index, ssh and privilege, package installs, recursive rm,
# the serial port, and the memory cap for test and build runners. It reads command text, so it can be wrong both ways.
role=worker
cmd=$(jq -r '.tool_input.command // empty')
deny() {
  jq -n --arg r "agent-bash-guard ($role): $1. The agent file forbids this; do the task without it or report BLOCKED. If you were only searching for this text, change the pattern (quote the pattern in single quotes, or e.g. grep -n 'git.stash' or 'ssh.')." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
has() { printf '%s' "$1" | command grep -qE -e "$2"; }   # -e: a pattern may start with --
# Remove single-quoted spans (bash expands nothing inside them), but only from simple read-only commands, so a quoted
# grep pattern or URL is not mistaken for a runner or a background &. Strips nothing unless the text outside the spans has no ', ", backtick,
# backslash, $, newline, #, parentheses, braces or << (then left-to-right pairing is exactly how bash pairs them), and every command
# word left after stripping is a plain read command. A runner, eval, bash -c or python -c is never one, so it is checked raw.
strip_sq() { python3 -I -c '
import re, sys
s = sys.argv[1]
READ = {"grep", "egrep", "fgrep", "rg", "echo", "printf", "curl", "head", "tail", "wc", "sort", "cut", "cat", "ls"}
out = re.sub(r"\x27[^\x27]*\x27", "", s)
if re.search(r"[\x22\x27`\\$\n#(){}]|<<", out):  # outside the spans: anything that changes how bash pairs quotes
    print(s); sys.exit()
words = [seg.split()[0] if seg.split() else "" for seg in re.split(r"[;&|]+", out)]
print(out if all(w in READ for w in words if w) else s)' "$1" 2>/dev/null || printf '%s' "$1"; }
B='(^|[^[:alnum:]_./-])'   # start of a command word
E='([^[:alnum:]_-]|$)'
C="(^|[;&|(\`]|then|do|(ba|z|da)?sh([[:space:]]+-[[:alnum:]]+)*[[:space:]]+-[[:alnum:]]*c[[:space:]]+[\'\"])[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|nice|time|nohup|exec|command|setsid|unshare([[:space:]]+-[[:alnum:]-]+)*|xargs|timeout[[:space:]]+[0-9.]+[a-z]?|uvx|uv[[:space:]]+run)[[:space:]]+)*([^[:space:]\'\"]*/)?(python[0-9.]*([[:space:]]+-[A-Za-z]+)*[[:space:]]+(-m[[:space:]]+)?)?(npx[[:space:]]+)?([^[:space:]\'\"]*/)?"   # command position (also inside bash -c '...' or "..."), so `pip show esptool` or grep 'pytest' is not a use

has "$cmd" "${B}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(stash|checkout|switch|reset|restore|clean|add|commit|merge|rebase|push|pull|cherry-pick|revert|am|apply|rm|mv)${E}" \
  && deny "git command that changes the shared working tree, index, stash or remote"
has "$cmd" "${B}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+branch[[:space:]]+(-[[:alnum:]]*[dDmM]|--delete|--move)" \
  && deny "git branch delete/rename"
rp='(ssh|scp|rsync|sudo|pkexec|yay)'
[[ $cmd =~ ^[\ $'\t']*ssh[\ $'\t']+-[VQ]([\ $'\t']+[A-Za-z0-9._-]+)?[\ $'\t']*$ ]] || \
  { has "$cmd" "${C}${rp}[[:space:]]" && deny "remote, privileged or system-package command"; }   # a whole-command `ssh -V` or `ssh -Q x` only prints
# pacman: only queries (-Q...); count every use against the -Q ones so `pacman -Q x; pacman -S y` is still caught
pm=$(printf '%s' "$cmd" | command grep -oE -e "${C}pacman[[:space:]]" | wc -l); pq=$(printf '%s' "$cmd" | command grep -oE -e "${C}pacman[[:space:]]+-Q[a-zA-Z]*([[:space:]]|\$)" | wc -l)
[ "$pm" -gt "$pq" ] && deny "pacman other than a -Q query"
has "$cmd" "(curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh${E}" && deny "piping a download into a shell"
has "$cmd" "${B}(pip3?|uv[[:space:]]+pip)[[:space:]]+install${E}|${B}npm[[:space:]]+(install|i|ci|add)${E}|${B}(uv|cargo|poetry|yarn|pnpm)[[:space:]]+add${E}|${C}(cargo|pipx)[[:space:]]+install${E}|${C}(yarn|pnpm|poetry|bundle|composer)[[:space:]]+(install|i)${E}|${C}uv[[:space:]]+sync${E}|${C}go[[:space:]]+(get|install)${E}" \
  && deny "installing dependencies"
has "$cmd" "${C}rm([[:space:]]+-[[:alnum:]]+)*[[:space:]]+(-[[:alnum:]]*[rR]|--recursive)" && deny "recursive rm"
# Serial port is one exclusive resource the planner owns (flashing, boot logs); a service that holds the serial port usually has it open.
bare_s=$(printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g")   # double-quoted text is a search pattern, not a device use
has "$bare_s" "(^|[[:space:]=<>'])/dev/(tty(USB|ACM)|serial/)|${C}(esptool|espflash|espefuse|espsecure)(\.py)?${E}|(^|[^[:alnum:]_-])idf\.py[^|;&]*[[:space:]][a-z_-]*(flash|monitor|erase|efuse|otadata|openocd|gdb|dfu|coredump)[a-z_-]*${E}|${B}(pio|platformio)[^|;&]*(-t|--target)[[:space:]=]*(upload|uploadfs|monitor|erase|program|fuses|bootloader)|${B}(pio|platformio)[[:space:]]+device[[:space:]]+monitor${E}|${C}(openocd|dfu-util|avrdude|probe-rs)${E}|${C}(cargo[[:space:]]+(espflash|flash|embed|run)|west[[:space:]]+flash|picotool)${E}|${B}(picocom|minicom|miniterm)[[:space:]]|${B}screen[[:space:]]+/dev/" \
  && deny "serial device or flashing command (only the orchestrator touches the board)"
# pio test uploads to the board unless every -e/--environment given is exactly native.
if has "$bare_s" "${B}(pio|platformio)[[:space:]]+test${E}"; then
  envs=$(printf '%s' "$bare_s" | tr "'" ' ' | command grep -oE '(^|[[:space:]])(-e|--environment)[[:space:]=]*[^[:space:]]+' | sed -E 's/.*(-e|--environment)[[:space:]=]*//')
  { [ -z "$envs" ] || printf '%s\n' "$envs" | command grep -qvx 'native'; } \
    && deny "pio test without -e native (exactly, and no other env) uploads to the board (only the orchestrator touches the board)"
fi

# A systemd-run scope without the slice and a MemoryMax is no cap, wherever the runner sits in it.
if has "$cmd" "${C}systemd-run[[:space:]]" && ! { has "$cmd" "--slice=orchestrate\.slice" && has "$cmd" "MemoryMax="; } \
   && has "$cmd" "${B}(pytest|unittest|tsc|gradle|gradlew|mvn|make|ctest|ninja|jest|vitest|mocha|tox|nox|bazel|rspec|phpunit)${E}|${B}(go[[:space:]]+(test|build|vet)|cargo[[:space:]]+(test|build|run|check|clippy|doc|bench)|(npm|yarn|pnpm)[[:space:]]+(test|run))${E}"; then
  deny "systemd-run without --slice=orchestrate.slice and MemoryMax= is not the memory cap: run it as systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd <Repo> && <command>'"
fi
# Test and build runners must run inside the shared memory cap (an uncapped suite once grew to 21 GB).
capcmd=$(printf '%s' "$cmd" | sed -E 's/[^;&|]*[[:space:]]--version[[:space:]]*($|[;&|])/\1/g')   # a `<tool> --version` segment is a check, not a run
has "$cmd" "(ba|z|da)?sh[[:space:]]+-[[:alnum:]]*c" || capcmd=$(strip_sq "$capcmd")   # single-quoted text is a pattern, unless it is a shell payload
if has "$capcmd" "${C}(pytest|unittest|tsc|gradle|gradlew|mvn|make|ctest|ninja|jest|vitest|mocha|tox|nox|bazel|rspec|phpunit)${E}|${C}(go[[:space:]]+(test|build|vet)|cargo[[:space:]]+(test|build|run|check|clippy|doc|bench)|cmake[[:space:]]+--build|(npm|yarn|pnpm)[[:space:]]+(test|run)|pio[[:space:]]+(run|test)|platformio[[:space:]]+(run|test))${E}|${C}idf\.py[^|;&]*[[:space:]](build|all|app)${E}" \
   && ! { has "$cmd" "systemd-run[[:space:]]+--user[[:space:]]+--scope" && has "$cmd" "--slice=orchestrate\.slice" && has "$cmd" "MemoryMax="; }; then
  deny "test or build command outside the memory cap: run it as systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd <Repo> && <command>'"
fi

exit 0
