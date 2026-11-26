#!/usr/bin/env python3
"""PreToolUse hook for Bash (main session and subagents): refuse a command that holds a literal credential.

A token typed into a command is already in the transcript when this runs, so the point is to stop the command from
sending it and to make the next attempt read the value from its file. It refuses each command once per session; the
same command retried passes, so a made-up value in a test is never locked out. It never asks the user, and any error
allows: it is a nudge. Design: docs/superpowers/specs/2026-11-25-credential-gate-design.md.
Tests: tests/test_credential_gate.sh.
"""
import hashlib, json, os, re, sys, time

LIT = r"(?=[A-Za-z0-9_.-]*[0-9])(?=[A-Za-z0-9_.-]*[A-Za-z])[A-Za-z0-9_.-]{10,}"   # starts at a literal character
Q, S = r"[\"']?", r"[ \t]*"   # an optional quote (JSON, Python dicts), blanks but never a newline
KINDS = (
    # With a scheme, or a bare host:port (curl localhost:3001/...). The anchor and the {0,8} bound keep the search
    # linear: unbounded, a long run of host characters or of back-to-back URL starts took seconds.
    ("a token in a push or webhook URL", re.compile(
        r"(?i)(?:https?://[^\s\"'/]+|(?<![A-Za-z0-9.-])[A-Za-z0-9.-]+:\d+)(?:/[^\s/?#\"']*){0,8}?/(?:push|webhooks?(?:/\d+)?|hooks)/" + LIT)),
    ("a credential in an HTTP header", re.compile(
        r"(?i)(?:authorization" + Q + S + ":" + S + Q + r"(?:bearer|token|basic)[ \t]+|(?:x-api-key|api[_-]?key|private-token)"
        + Q + S + ":" + S + Q + ")" + LIT)),
)


def main():
    try:
        ev = json.load(sys.stdin)
        cmd, sid = ev.get("tool_input", {}).get("command") or "", ev.get("session_id") or ""
        kind = next((k for k, p in KINDS if p.search(cmd)), None)
        if not kind or not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
            return
        st = os.path.expanduser("~/.local/state/orchestrate")
        os.makedirs(st, mode=0o700, exist_ok=True)
        for f in os.listdir(st):   # prune markers older than a day; a failure here never skips the refusal
            try:
                p = os.path.join(st, f)
                if f.startswith("cred-gate-") and time.time() - os.path.getmtime(p) > 86400:
                    os.unlink(p)
            except OSError:
                pass
        mark = os.path.join(st, "cred-gate-%s-%s" % (sid, hashlib.sha256(cmd.encode()).hexdigest()[:16]))
        open(mark, "x").close()   # exists already: this is the retry, let it through
    except Exception:
        return
    why = ("credential-gate: this command holds %s as a literal value. Do not retype credentials: pass it from its "
           "file, e.g. -H \"X-Api-Key: $(cat <file>)\" or a URL built from $(cat <file>), and never print it. "
           "If the value is made up (a test), retry the same command; this gate refuses each command once." % kind)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": why}}))


if __name__ == "__main__":
    main()
