#!/usr/bin/env python3
"""PreToolUse hook for mcp__grafana__grafana_api_request: allow only GET paths that fully match an allow-list regex.

Usage (agent frontmatter): python3 -I grafana_api_guard.py '<regex>'
The tool can reach any Grafana API path and, through the datasource proxy, any GET path of any datasource, so a
read-only agent gets it only behind this guard. Allow = no output. Everything else, including bad input, a missing or
invalid regex and any error, is a deny: this is a guard, not a nudge. The query string (after the first "?") is not
inspected beyond whitespace and control characters; it is the query itself and goes only to the allowed path.
Limit: a deny is JSON on stdout. If Python cannot start at all (missing interpreter), Claude Code treats the failed hook
as non-blocking and the call goes through; every error inside the script is caught and denies.
Design: docs/superpowers/specs/2026-11-25-grafana-api-guard-design.md. Tests: tests/test_grafana_api_guard.sh.
"""
import json, re, sys

KEYS = {"endpoint", "method", "headers", "jq"}   # exact case: mcp-grafana matches argument names case-insensitively,
                                                  # so an extra "Endpoint" would be the one it sends


def why():
    if len(sys.argv) != 2:
        return "no allow-list regex given (frontmatter: python3 -I grafana_api_guard.py '<regex>')"
    rx = re.compile(sys.argv[1])
    ti = json.load(sys.stdin).get("tool_input")
    if not isinstance(ti, dict):
        return "tool_input is not an object"
    if not set(ti) <= KEYS:
        return f"unexpected argument(s) {sorted(set(ti) - KEYS)}: only {sorted(KEYS)}, exact case"
    endpoint, method, headers = ti.get("endpoint"), ti.get("method"), ti.get("headers")
    if method not in (None, "", "GET"):
        return f"method {method!r}: only GET"
    if headers:
        return "headers are not allowed"
    if not isinstance(endpoint, str) or not endpoint:
        return "endpoint missing or not a string"
    if "#" in endpoint:
        return "a fragment (#) in the endpoint"
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in endpoint):
        return "whitespace or a control character in the endpoint"
    path = endpoint.split("?", 1)[0]
    for bad in ("%", "..", "//", "\\"):
        if bad in path:
            return f"{bad!r} in the path"
    if not rx.fullmatch(path):
        return f"path {path} is not on this agent's allow-list"
    return None


def main():
    try:
        reason = why()
    except Exception as e:   # bad JSON, invalid regex, anything: deny
        reason = f"could not check the call ({type(e).__name__})"
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": "grafana_api_guard: " + reason}}))


if __name__ == "__main__":
    main()
