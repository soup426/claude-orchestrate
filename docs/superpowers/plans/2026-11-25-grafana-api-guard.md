# Grafana API guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PreToolUse hook that allows `mcp__grafana__grafana_api_request` only on GET paths matching an allow-list regex.

**Architecture:** One stdlib Python hook, `python3 -I hooks/grafana_api_guard.py <regex>`, reading the hook JSON on stdin and printing a deny decision or nothing. Wired per agent in its frontmatter; the regex is the agent file's, not the repo's.

**Tech Stack:** Python 3 stdlib (json, re, sys), bash test script in the repo's style (tests/test_*.sh).

**Spec:** docs/superpowers/specs/2026-11-25-grafana-api-guard-design.md

## Global Constraints

- Deny = stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"grafana_api_guard: ..."}}`, exit 0. Allow = no output, exit 0.
- Fail closed: bad JSON, missing or invalid regex, non-string endpoint, any exception -> deny.
- The query string (after the first `?`) is never inspected.

## Review Focus

- Encoded traversal in the path (`%2e%2e`, `%2f`): a person expects deny. Test: path with `%2e%2e` -> deny.
- A matching prefix with extra path (`.../query/../../snapshot/list`): expect deny. Test with `..`.
- `method` "get" in lower case or "HEAD": the tool only knows GET; expect deny for anything but absent, "" or "GET". Test "POST" and "get".
- `headers` set to `{}` (empty) vs a real header: empty is allowed, any header denies. Test both.
- The regex argument missing (frontmatter typo): expect deny with a reason naming the guard. Test no argument.

---

### Task 1: grafana_api_guard hook

**Files:**
- Create: `hooks/grafana_api_guard.py`
- Create: `tests/test_grafana_api_guard.sh`
- Modify: `tests/run.sh` (add the new test to the list)
- Modify: `README.md` (one bullet next to the other optional gates)
- Private, after review: `~/.claude/agents/inspector.md` (tools line + frontmatter hook + one bullet), `~/.claude/hooks/grafana_api_guard.py` (byte-identical copy)

**Interfaces:**
- Produces: `python3 -I grafana_api_guard.py <regex>`; stdin hook JSON with `tool_input.{endpoint,method,headers}`.

- [ ] **Step 1: Write the failing test** `tests/test_grafana_api_guard.sh`, helper `t <allow|deny> <label> <endpoint> [method] [headers-json] [regex]`, regex default `^/api/datasources/proxy/uid/vl/select/logsql/(query|hits|stats_query|stats_query_range|field_names|field_values)$`. Cases:
  - allow `/api/datasources/proxy/uid/vl/select/logsql/query?query=_time%3A1h%20%2A%20%7C%20stats%20count%28%29`
  - allow `.../field_names?query=*` ; allow with method `GET` ; allow with headers `{}`
  - deny `/api/datasources/proxy/uid/vm/snapshot/list` ; deny `/api/datasources/proxy/uid/vl/internal/force_flush`
  - deny `/api/v1/provisioning/contact-points` ; deny `/api/datasources/proxy/uid/vl/select/logsql/query/../../../snapshot/list`
  - deny `/api/datasources/proxy/uid/vl/select/logsql/%2e%2e/x` ; deny `//api/...query` ; deny path with `\`
  - deny endpoint with `#` ; deny method `POST` ; deny method `get` ; deny headers `{"X-HTTP-Method-Override":"DELETE"}`
  - deny no regex argument ; deny invalid regex `(` ; deny bad JSON ; deny endpoint not a string (`123`)
  - the deny reason starts with `grafana_api_guard:`
- [ ] **Step 2: Run** `bash tests/test_grafana_api_guard.sh` -> every case fails (no hook file).
- [ ] **Step 3: Implement** `hooks/grafana_api_guard.py`: `main()` reads stdin, applies the spec's checks in order, prints the deny JSON with a short reason, else nothing.
- [ ] **Step 4: Run** the test -> `grafana-api-guard cases=N fails=0`; then `bash tests/run.sh` under the memory cap -> ALL PASS.
- [ ] **Step 5: Commit** the hook, test, run.sh, README, spec and this plan.
- [ ] **Step 6: Review** reviewer + security on the commit; fix FAILs, re-run once.
- [ ] **Step 7: Install and wire** copy the hook to `~/.claude/hooks/` (cmp identical), edit the private inspector, `scripts/check_drift.sh` (hooks identical), push.
- [ ] **Step 8: Live check** one inspector run: error counts per hostname over 24 h via the proxy route; transcript shows a `grafana_api_request` call that ran, and one deliberate disallowed call (`/api/datasources/proxy/uid/vm/snapshot/list`) refused by the guard.
