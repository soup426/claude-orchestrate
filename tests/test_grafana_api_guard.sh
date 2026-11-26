#!/usr/bin/env bash
# Tests for hooks/grafana_api_guard.py. Usage: bash tests/test_grafana_api_guard.sh [hook path]
H=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/grafana_api_guard.py}
RX='^/api/datasources/proxy/uid/vl/select/logsql/(query|hits|stats_query|stats_query_range|field_names|field_values)$'
P=/api/datasources/proxy/uid/vl/select/logsql
n=0 fails=0
decide() {  # decide <raw stdin> [regex args...]: prints allow or deny
  local in=$1; shift
  local out; out=$(printf '%s' "$in" | python3 -I "$H" "$@" 2>/dev/null)
  if [ -z "$out" ]; then echo allow
  elif [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ]; then echo deny
  else echo "other:$out"; fi
}
t() {  # t <want> <label> <endpoint> [method] [headers-json]
  n=$((n+1))
  local in; in=$(jq -cn --arg e "$3" --arg m "${4-__none__}" --argjson h "${5:-null}" \
    '{tool_name:"mcp__grafana__grafana_api_request", tool_input:({endpoint:$e} + (if $m == "__none__" then {} else {method:$m} end) + (if $h == null then {} else {headers:$h} end))}')
  local got; got=$(decide "$in" "$RX")
  [ "$got" = "$1" ] || { echo "WRONG want=$1 got=$got: $2"; fails=$((fails+1)); }
}
t allow "LogsQL stats query" "$P/query?query=_time%3A1h%20%2A%20%7C%20stats%20count%28%29"
t allow "field_names" "$P/field_names?query=*"
t allow "explicit GET" "$P/hits?query=error" GET
t allow "empty method" "$P/query?query=x" ""
t allow "empty headers" "$P/query?query=x" GET '{}'
t allow "query string may hold %2F and .. (LogsQL)" "$P/query?query=path%3A%22..%2Fetc%22"
t deny  "other datasource admin path" /api/datasources/proxy/uid/vm/snapshot/list
t deny  "same datasource, other path" /api/datasources/proxy/uid/vl/internal/force_flush
t deny  "other Grafana API" /api/v1/provisioning/contact-points
t deny  "dot-dot after an allowed prefix" "$P/query/../../../snapshot/list"
t deny  "encoded dot-dot" "$P/%2e%2e/x"
t deny  "encoded slash in the path" "$P/query%2Fx"
t deny  "double slash" "/$P/query?query=x"
t deny  "backslash" "$P/query\\x"
t deny  "fragment" "$P/query?query=x#y"
t deny  "POST" "$P/query?query=x" POST
t deny  "lower-case get" "$P/query?query=x" get
t deny  "HEAD" "$P/query?query=x" HEAD
t deny  "a header" "$P/query?query=x" GET '{"X-HTTP-Method-Override":"DELETE"}'
t deny  "prefix only" "$P/query_extra?query=x"
# fail closed
in=$(jq -cn --arg e "$P/query?query=x" '{tool_input:{endpoint:$e}}')
n=$((n+1)); [ "$(decide "$in")" = deny ] || { echo "WRONG: no regex argument must deny"; fails=$((fails+1)); }
n=$((n+1)); [ "$(decide "$in" '(')" = deny ] || { echo "WRONG: an invalid regex must deny"; fails=$((fails+1)); }
n=$((n+1)); [ "$(decide 'not json' "$RX")" = deny ] || { echo "WRONG: bad JSON must deny"; fails=$((fails+1)); }
n=$((n+1)); [ "$(decide '{"tool_input":{"endpoint":123}}' "$RX")" = deny ] || { echo "WRONG: a non-string endpoint must deny"; fails=$((fails+1)); }
n=$((n+1)); [ "$(decide '{"tool_input":{}}' "$RX")" = deny ] || { echo "WRONG: a missing endpoint must deny"; fails=$((fails+1)); }
n=$((n+1)); out=$(printf '%s' '{"tool_input":{"endpoint":"/api/x"}}' | python3 -I "$H" "$RX" 2>/dev/null)
case $(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null) in
  "grafana_api_guard: "*) ;; *) echo "WRONG: the deny reason must start with grafana_api_guard:"; fails=$((fails+1)) ;; esac
echo "grafana-api-guard cases=$n fails=$fails"; [ "$fails" -eq 0 ]
