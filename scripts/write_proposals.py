#!/usr/bin/env python3
"""Write skill-change proposals as markdown files (used by the reflect skill).

Reads {"proposals": [...]} as JSON on stdin and writes one file per proposal to
--out (default ~/.claude/skill-proposals). All proposals are validated first;
if any is bad, or a target file already exists, nothing is written and the exit
code is 90. Existing files are never overwritten.
"""
import argparse
import datetime
import json
import os
import re
import sys

BAD_INPUT = 90
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
TARGET = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
CONFIDENCE = ("high", "medium", "low")


def check(i, p):
    """Return an error string for proposal i, or None if it is valid."""
    if not isinstance(p, dict):
        return f"proposal {i}: not an object"
    if p.get("kind") not in ("edit", "new"):
        return f"proposal {i}: kind must be 'edit' or 'new'"
    if p["kind"] == "edit" and not (isinstance(p.get("target"), str) and TARGET.fullmatch(p["target"])):
        return f"proposal {i}: an edit needs a target (a skill name, no spaces or slashes)"
    if not (isinstance(p.get("slug"), str) and SLUG.fullmatch(p["slug"])):
        return f"proposal {i}: slug must be kebab-case (a-z, 0-9, -), at most 64 chars"
    if p.get("confidence") not in CONFIDENCE:
        return f"proposal {i}: confidence must be one of {', '.join(CONFIDENCE)}"
    src = p.get("sources")
    if not (isinstance(src, list) and src and all(isinstance(x, str) and x.strip() and "\n" not in x for x in src)):
        return f"proposal {i}: sources must be a non-empty list of one-line strings"
    for k in ("title", "body"):
        if not (isinstance(p.get(k), str) and p[k].strip()):
            return f"proposal {i}: {k} must be a non-empty string"
    if "\n" in p["title"]:
        return f"proposal {i}: title must be one line"
    return None


def render(p, now):
    # JSON strings are valid YAML scalars, so json.dumps quotes every value safely.
    q = json.dumps
    head = ["---", f"kind: {p['kind']}"]
    if p["kind"] == "edit":
        head.append(f"target: {q(p['target'])}")
    head += [f"confidence: {p['confidence']}", "sources:"]
    head += [f"  - {q(x)}" for x in p["sources"]]
    head += [f"generated: {now}", "---", f"# {p['title']}", "", p["body"].rstrip(), ""]
    return "\n".join(head)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=os.path.expanduser("~/.claude/skill-proposals"))
    out = ap.parse_args().out

    try:
        raw = sys.stdin.read(1_000_001)  # proposals are small; refuse anything over 1 MB
        if len(raw) > 1_000_000:
            raise ValueError("input over 1 MB")
        props = json.loads(raw)["proposals"]
        assert isinstance(props, list)
    except (ValueError, KeyError, TypeError, AssertionError) as e:
        sys.exit(_bad(f"stdin must be JSON like {{\"proposals\": [...]}}: {e!r}"))

    errs = [e for e in (check(i, p) for i, p in enumerate(props)) if e]
    if errs:
        sys.exit(_bad("; ".join(errs)))

    stamp = datetime.datetime.now(datetime.timezone.utc)
    paths = [os.path.join(out, f"{stamp:%Y%m%d}-{p['slug']}.md") for p in props]
    dup = [x for x in paths if os.path.exists(x) or paths.count(x) > 1]
    if dup:
        sys.exit(_bad(f"would overwrite or duplicate: {', '.join(sorted(set(dup)))}"))

    now = f"{stamp:%Y-%m-%dT%H:%M:%SZ}"
    try:  # encode everything before creating any file, so a bad string cannot leave a partial batch
        bodies = [render(p, now).encode("utf-8") for p in props]
    except UnicodeEncodeError as e:
        sys.exit(_bad(f"proposal text is not valid UTF-8: {e!r}"))
    os.makedirs(out, exist_ok=True)
    for path, body in zip(paths, bodies):
        with open(path, "xb") as f:  # "x": never overwrite, even on a race
            f.write(body)
        print(path)


def _bad(msg):
    print(f"write_proposals: {msg}", file=sys.stderr)
    return BAD_INPUT


if __name__ == "__main__":
    main()
