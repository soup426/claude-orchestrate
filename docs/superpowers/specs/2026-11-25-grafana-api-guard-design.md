# Grafana API guard (short design, 2026-11-25, approved)

**Why.** The Grafana MCP's `query_loki_logs` returns nothing for a VictoriaLogs LogsQL query with `| stats`, `| sort`
or `| field_names`. `grafana_api_request` can run them through Grafana's datasource proxy
(`GET /api/datasources/proxy/uid/<uid>/select/logsql/query?query=...`), but that tool reaches any Grafana API path
and, through the proxy, any GET path on any datasource (snapshot, reload, force-merge endpoints answered GET until
their auth keys were set). A read-only agent that reads untrusted log text must not hold it on prose alone.

**Goal.** A PreToolUse hook that lets an agent call `mcp__grafana__grafana_api_request` only on paths matching an
allow-list regex given as its argument. Non-goals: guarding the main session, other MCP tools, or POST (the tool is
GET-only in read-only mode, but the hook still checks). Anti-goal: an allow-list in the public repo that names a
user's datasources; the regex lives in the user's private agent file.

**Approaches.** (a) Frontmatter hook with the regex as its argument: chosen, the same pattern as agent-report-gate.
(b) ssh plus curl to the datasource on its host: needs a new login on the host. (c) A wrapper MCP server: far more code.

**Design.** `hooks/grafana_api_guard.py <regex>`, run as `python3 -I`. It denies (PreToolUse `permissionDecision: deny`
with a reason) unless all hold: `method` is absent, empty or `GET`; `headers` is absent or empty; `endpoint` is a string
with no `#`; the part before `?` contains no `%`, `..`, `//` or backslash and fully matches the regex. Anything else,
including bad input, a missing or invalid regex, or an exception, denies. The query string is not inspected: it is the
LogsQL itself and goes only to the allowed path. Tests: `tests/test_grafana_api_guard.sh`, added to `tests/run.sh`.

**Wiring (private copy).** `inspector.md` lists the tool and adds, under `hooks: PreToolUse`, matcher
`mcp__grafana__grafana_api_request` running the guard with
`^/api/datasources/proxy/uid/vl/select/logsql/(query|hits|stats_query|stats_query_range|field_names|field_values)$`.
