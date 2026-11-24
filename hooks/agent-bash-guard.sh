#!/usr/bin/env bash
# PreToolUse hook (Bash) for the orchestrate agents, wired in each agent's frontmatter with its role as $1.
# Enforces what the agent files say in prose: shared-tree git bans, no remote/install/privilege, no recursive rm;
# reviewer, researcher and security are read-only. Git/remote checks scan the raw text (catches bash -c '...'); the write checks
# for read-only roles scan the text with quoted strings removed, so `python3 -c "assert a > b"` is not a redirect.
role=${1:-worker}
cmd=$(jq -r '.tool_input.command // empty')
case $role in
  worker) out="report BLOCKED" ;; inspector) out="list it under COULD NOT CHECK" ;; researcher) out="list it under UNVERIFIED" ;;
  *) out="list it under NOT JUDGED" ;;
esac
deny() {
  jq -n --arg r "agent-bash-guard ($role): $1. The agent file forbids this; do the task without it or $out. If you were only searching for this text, change the pattern (quote the pattern in single quotes, or e.g. grep -n 'git.stash' or 'ssh.')." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
has() { printf '%s' "$1" | command grep -qE -e "$2"; }   # -e: a pattern may start with --
# Read-only roles: a plain redirect (> or >>) or `mkdir -p` whose target is a bare path inside this machine's session
# scratchpads (/tmp/claude-<uid>/<project>/<session>/scratchpad/...) is not a write to the user's files. The target must
# be a plain token (letters, digits, . _ - /; no quotes, $, backticks, globs, ..) that still resolves inside the
# scratchpad after following symlinks. For `cat > <scratch file> <<'X'` the quoted here-doc body is data and is not
# scanned. Everything else is left for the write checks below.
drop_scratch() { python3 -I -c '
import os, re, sys
s = sys.argv[1]
TOK = r"/tmp/claude-[0-9]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/scratchpad(?:/[A-Za-z0-9_.-]+)*/?"
def ok(x):
    if not re.fullmatch(TOK, x) or ".." in x.split("/") or "." in x.split("/"):
        return False
    root = os.path.realpath("/".join(x.split("/")[:6]))
    real = os.path.realpath(x)
    return real == root or real.startswith(root + "/")
lines = s.split("\n")
head = lines[0]
m = re.search(r"<<-?\s*([\x27\x22])([A-Za-z_][A-Za-z0-9_]*)\1\s*$", head)
if m and len(lines) > 1:
    end = next((i for i in range(1, len(lines)) if re.fullmatch(re.escape(m.group(2)) + r"\s*(;.*)?", lines[i].strip())), None)
    hm = re.fullmatch(r"\s*cat\s+>\s*(\S+)\s+<<-?\s*([\x27\x22])" + re.escape(m.group(2)) + r"\2\s*", head)
    if end is not None and hm and ok(hm.group(1)):   # only `cat > <scratch file> <<'X'` and nothing else on the line
        lines = [head] + lines[end + 1:]
s = "\n".join(lines)
s = re.sub(r"(^|[\s;&|])[0-9]?>>?\s*([^\s;&|<>()]+)(?=$|[\s;&|])", lambda m: m.group(1) if ok(m.group(2)) else m.group(0), s)
s = re.sub(r"(^|[;&|]\s*|\n)mkdir\s+-p((?:\s+[^\s;&|<>()]+)+)\s*(?=$|[;&|\n])", lambda m: m.group(1) if all(ok(a) for a in m.group(2).split()) else m.group(0), s)
print(s)' "$1" 2>/dev/null || printf '%s' "$1"; }
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
# The verifier may ssh only when the WHOLE command is a read-only probe that the inspector's allow-list accepts.
if [ "$role" = verifier ] && has "$cmd" "(^|[^[:alnum:]_.-])ssh${E}"; then   # the word anywhere, path forms too: { ssh, if ssh, /usr/bin/ssh, ./ssh, x=/usr/bin/ssh
  why=$(python3 -I "$(dirname "$0")/inspector_guard.py" --require-check "$cmd" 2>&1) || deny "ssh from the verifier must be a read-only probe (the whole command is checked like the inspector's): $why"
fi
if [ "$role" = inspector ] || [ "$role" = verifier ]; then rp='(scp|rsync|sudo|pkexec|yay)'; else rp='(ssh|scp|rsync|sudo|pkexec|yay)'; fi
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

# The verifier may run servers, but never detached: no daemons, no background, no compose up -d.
if [ "$role" = verifier ]; then
  vq=$(strip_sq "$cmd")   # an & inside a single-quoted URL is not a background job...
  has "$cmd" "(ba|z|da)?sh[[:space:]]+-[[:alnum:]]*c" && vq=$cmd                     # ...unless the quotes hold a shell payload
  has "$vq" "(^|[^&>])&([^&>]|$)" && deny "background process with & (the verifier's servers must end with their timeout)"
  has "$cmd" "${C}(nohup|setsid|disown|daemonize)${E}|docker([[:space:]].*)?[[:space:]](up|run)[[:space:]].*-d${E}|--detach" && deny "detached or background process (the verifier's servers must end with their timeout)"
  has "$cmd" "http\.server" && ! has "$cmd" "--bind[[:space:]=]+127\.0\.0\.1|-b[[:space:]]+127\.0\.0\.1" && deny "http.server without --bind 127.0.0.1"
  runs=$(printf '%s' "$cmd" | command grep -oE -e 'systemd-run' | wc -l); scoped=$(printf '%s' "$cmd" | command grep -oE -e 'systemd-run[[:space:]]+--user[[:space:]]+--scope' | wc -l)
  [ "$runs" -gt "$scoped" ] && deny "systemd-run without --user --scope starts a detached service"
  has "$cmd" "${C}(tmux[[:space:]]+(new|new-session)[^;&|]*-d|at|batch)${E}|${C}screen[[:space:]]+-[a-zA-Z]*d" && deny "detached session or scheduled job"
  has "$cmd" "--host[[:space:]=]+(0\.0\.0\.0|::)|--bind[[:space:]=]+(0\.0\.0\.0|::)|-H[[:space:]]+0\.0\.0\.0" && deny "server bound to all interfaces (use 127.0.0.1)"
fi

# The inspector may ssh, but only to read: an allow-list parser checks every command word, local and remote
# (inside ssh '...', pct exec --, sh -c, $(...)), and anything unknown is denied.
if [ "$role" = inspector ]; then
  why=$(python3 -I "$(dirname "$0")/inspector_guard.py" --require-check "$cmd" 2>&1) || deny "not a read-only probe: $why"
fi

if [ "$role" != worker ]; then
  # The capped form puts the real command inside bash -c '...': scan those payloads as commands, not as quoted text.
  inner=$(printf '%s' "$cmd" | command grep -oE "(ba|z)?sh[^'\"]*[[:space:]]-[[:alnum:]]*c[[:space:]]+('[^']*'|\"[^\"]*\")" | sed -E "s/^(ba|z)?sh[^'\"]*[[:space:]]-[[:alnum:]]*c[[:space:]]+['\"]//; s/['\"]\$//")
  bare=$(drop_scratch "$(printf '%s ; %s' "$cmd" "$inner")" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g; s#[0-9]?>>?[[:space:]]*/dev/null##g; s/[0-9]?>&[0-9]//g")
  has "$bare" "${B}sed[[:space:]]+(-[[:alnum:]]*i|--in-place)" && deny "in-place edit (read-only role)"
  has "$bare" "${B}(rm|mv|cp|tee|truncate|touch|mkdir|ln|wget|patch|chmod|chown|dd)[[:space:]]" && deny "file-writing command (read-only role)"
  bare=$(printf '%s' "$bare" | sed -E 's#(^|[[:space:]])(-o|--output)[[:space:]=]+/dev/null##g')   # discarding output is not a write
  has "$bare" "${B}curl[^|;&]*[[:space:]](-[[:alnum:]]*[oO]|--output|--remote-name)|${B}git[[:space:]]+clone${E}|${B}gh[[:space:]]+repo[[:space:]]+clone${E}|${B}perl[[:space:]]+-[[:alnum:]]*i" && deny "download or in-place write (read-only role)"
  has "$bare" "(^|[^<>=-])>>?[[:space:]]*[^[:space:]&=]" && deny "output redirect into a file (read-only role)"
fi
exit 0
