#!/usr/bin/env python3
"""Was code changed after the last reviewer run? Usage: review_owed.py <transcript.jsonl> <home>
Prints the tool-call index of the newest unreviewed change, or "no". Used by review-stop-gate.sh and
main-bash-cap-gate.sh. Counts main-session changes under ~/Projects, ~/.claude/hooks and ~/.claude/agents."""
import json, os, re, shlex, sys

path, home = sys.argv[1], sys.argv[2]
roots = tuple(home + d for d in ("/Projects/", "/.claude/hooks/", "/.claude/agents/"))
code = lambda f: "/.claude/agents/" in f or not f.endswith((".md", ".txt"))   # agent files are .md but are code
SEPS = {"|", "||", "&&", ";", "&", "|&", ";;", "(", ")"}
REDIR = {">", ">>", ">|", "&>", ">&", "&>>"}
PREFIX = {"sudo", "env", "command", "nice", "time", "nohup", "exec", "then", "do", "else", "{", "!"}


def expand(p):   # the home path spelled as ~, $HOME or ${HOME}
    return re.sub(r"^(~|\$HOME|\$\{HOME\})(?=/)", home, p)


def words_of(line):
    lx = shlex.shlex(line, posix=False, punctuation_chars=True)   # non-posix keeps quotes, so a quoted '>' is a word
    lx.whitespace_split = True
    toks = list(lx)
    if any(t.count('"') % 2 or t.count("'") % 2 for t in toks):
        raise ValueError("unbalanced quotes")
    out = []
    for t in toks:
        d = t.replace('"', "").replace("'", "")
        out.append(t if d == t else ("\0" + d if d in SEPS or d in REDIR or d == "<" else d))   # quoted operator: a word
    return out


def seg_targets(w, out):   # one simple command's words, prefixes stripped: what it writes
    while w and (w[0] in PREFIX or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", w[0])):
        w = w[1:]
    if w and w[0] == "timeout":
        w = w[2:]
    if not w:
        return
    cmd, args = os.path.basename(w[0]), w[1:]
    if cmd == "tee" or (cmd == "sed" and any(re.fullmatch(r"-[a-zA-Z]*i\S*|--in-place\S*", x) for x in args)):
        out += [x for x in args if not x.startswith("-")]
    elif cmd in ("cp", "mv", "install", "ln", "rsync"):
        for k, x in enumerate(args):
            if x in ("-t", "--target-directory") and k + 1 < len(args):
                return out.append(args[k + 1])
            if x.startswith("--target-directory="):
                return out.append(x.split("=", 1)[1])
            if re.fullmatch(r"-[a-zA-Z]*t.+", x) and cmd != "rsync":
                return out.append(x[x.index("t") + 1:])
        pos = [x for x in args if not x.startswith("-")]
        if len(pos) > 1:
            out.append(pos[-1])


def targets(cmd):   # files a command writes: redirect targets, tee args, sed -i files, cp/mv/install destinations
    out = []
    for line in cmd.split("\n"):
        try:
            toks = words_of(line)
        except ValueError:   # unbalanced quotes (a here-doc body, say): fall back to unquoted redirect targets
            out += re.findall(r">>?\|?\s*['\"]?([^\s'\"<>|;&()]+)", line)
            continue
        seg, k = [], 0
        while k < len(toks):
            t = toks[k]
            if t in REDIR:
                if seg and seg[-1].isdigit():
                    seg.pop()   # the fd number in 2>file belongs to the redirect, not the command
                if k + 1 < len(toks) and not re.fullmatch(r"[0-9]+-?|-", toks[k + 1]):
                    out.append(toks[k + 1])
                k += 2
                continue
            if t in SEPS or t == "<":
                if t == "<":
                    k += 1   # skip the input file
                seg_targets(seg, out)
                seg = [] if t != "<" else seg
                k += 1
                continue
            seg.append(t)
            k += 1
        seg_targets(seg, out)
    return [expand(x) for x in out]
last_edit = last_review = -1
n = 0   # counts tool calls in order, so two calls in one message keep their order
for line in open(path, errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("isSidechain"):
        continue
    c = e.get("message", {}).get("content")
    if not isinstance(c, list):
        continue
    for b in c:
        if b.get("type") != "tool_use":
            continue
        n += 1
        i = b.get("input") or {}
        f = str(i.get("file_path") or i.get("notebook_path") or "")
        if b.get("name") in ("Edit", "Write", "MultiEdit", "NotebookEdit") and f.startswith(roots) and code(f):
            last_edit = n
        if b.get("name") == "Bash":
            cmd = str(i.get("command") or "")
            if any(t.startswith(roots) and code(t) for t in targets(cmd)):
                last_edit = n
        if b.get("name") == "Agent" and i.get("subagent_type") == "reviewer":
            last_review = n
print(last_edit if last_edit > last_review else "no")
