#!/usr/bin/env bash
# PreToolUse hook (Bash) for the orchestrate agents, wired in each agent's frontmatter with its role as $1.
# Enforces what the agent files say in prose: shared-tree git bans, no remote/install/privilege, no recursive rm;
# tester and reviewer are read-only. Git/remote checks scan the raw text (catches bash -c '...'); the write checks
# for read-only roles scan the text with quoted strings removed, so `python3 -c "assert a > b"` is not a redirect.
role=${1:-worker}
cmd=$(jq -r '.tool_input.command // empty')
deny() {
  jq -n --arg r "agent-bash-guard ($role): $1. The agent file forbids this; do the task without it or report BLOCKED. If you were only searching for this text, change the pattern (quote the pattern in single quotes, or e.g. grep -n 'git.stash' or 'ssh.')." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
has() { printf '%s' "$1" | command grep -qE "$2"; }
B='(^|[^[:alnum:]_./-])'   # start of a command word
E='([^[:alnum:]_-]|$)'
C="(^|[;&|(\`]|then|do|(ba|z|da)?sh([[:space:]]+-[[:alnum:]]+)*[[:space:]]+-[[:alnum:]]*c[[:space:]]+[\'\"])[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|nice|time|nohup|exec|command|setsid|xargs|timeout[[:space:]]+[0-9.]+[a-z]?|uvx|uv[[:space:]]+run)[[:space:]]+)*([^[:space:]\'\"]*/)?(python[0-9.]*[[:space:]]+(-m[[:space:]]+)?)?(npx[[:space:]]+)?([^[:space:]\'\"]*/)?"   # command position (also inside bash -c '...' or "..."), so `pip show esptool` or grep 'pytest' is not a use

has "$cmd" "${B}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(stash|checkout|switch|reset|restore|clean|add|commit|merge|rebase|push|pull|cherry-pick|revert|am|apply|rm|mv)${E}" \
  && deny "git command that changes the shared working tree, index, stash or remote"
has "$cmd" "${B}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+branch[[:space:]]+(-[[:alnum:]]*[dDmM]|--delete|--move)" \
  && deny "git branch delete/rename"
has "$cmd" "${C}(ssh|scp|rsync|sudo|pkexec|pacman|yay)[[:space:]]" && deny "remote, privileged or system-package command"
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

# Test and build runners must run inside the shared memory cap (an uncapped suite once grew to 21 GB).
capcmd=$(printf '%s' "$cmd" | sed -E 's/[^;&|]*[[:space:]]--version[[:space:]]*($|[;&|])/\1/g')   # a `<tool> --version` segment is a check, not a run
if has "$capcmd" "${C}(pytest|unittest|tsc|gradle|gradlew|mvn|make|ctest|ninja|jest|vitest|mocha|tox|nox|bazel|rspec|phpunit)${E}|${C}(go[[:space:]]+(test|build|vet)|cargo[[:space:]]+(test|build|run|check|clippy|doc|bench)|cmake[[:space:]]+--build|(npm|yarn|pnpm)[[:space:]]+(test|run)|pio[[:space:]]+(run|test)|platformio[[:space:]]+(run|test))${E}|${C}idf\.py[^|;&]*[[:space:]](build|all|app)${E}" \
   && ! has "$cmd" "systemd-run[[:space:]]+--user[[:space:]]+--scope"; then
  deny "test or build command outside the memory cap: run it as systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd <Repo> && <command>'"
fi

if [ "$role" != worker ]; then
  # The capped form puts the real command inside bash -c '...': scan those payloads as commands, not as quoted text.
  inner=$(printf '%s' "$cmd" | command grep -oE "(ba|z)?sh[^'\"]*[[:space:]]-[[:alnum:]]*c[[:space:]]+('[^']*'|\"[^\"]*\")" | sed -E "s/^(ba|z)?sh[^'\"]*[[:space:]]-[[:alnum:]]*c[[:space:]]+['\"]//; s/['\"]\$//")
  bare=$(printf '%s ; %s' "$cmd" "$inner" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g; s#[0-9]?>>?[[:space:]]*/dev/null##g; s/[0-9]?>&[0-9]//g")
  has "$bare" "${B}sed[[:space:]]+(-[[:alnum:]]*i|--in-place)" && deny "in-place edit (read-only role)"
  has "$bare" "${B}(rm|mv|cp|tee|truncate|touch|mkdir|ln|wget|patch|chmod|chown|dd)[[:space:]]" && deny "file-writing command (read-only role)"
  has "$bare" "${B}curl[^|;&]*[[:space:]](-[[:alnum:]]*[oO]|--output|--remote-name)|${B}git[[:space:]]+clone${E}|${B}gh[[:space:]]+repo[[:space:]]+clone${E}|${B}perl[[:space:]]+-[[:alnum:]]*i" && deny "download or in-place write (read-only role)"
  has "$bare" "(^|[^<>=-])>>?[[:space:]]*[^[:space:]&=]" && deny "output redirect into a file (read-only role)"
fi
exit 0
