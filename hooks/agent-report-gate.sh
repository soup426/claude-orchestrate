#!/usr/bin/env bash
# Report-format gate for the orchestrate agents: frontmatter PreToolUse hook on SubagentHandback, role as $1.
# Refuses a hand-back whose report lacks the role's required first field, so the agent re-sends it in format.
# Hard limit: at most ONE refusal per agent (keyed on agent_id); any later hand-back always passes, so a bug here
# can never lock an agent out of reporting (an early test showed an always-deny loop of 8 attempts).
role=${1:-worker}
in=$(cat)
id=$(printf '%s' "$in" | jq -j '.agent_id // .session_id // "unknown"' | tr -c '[:alnum:]_-' _)
state=${ORCHESTRATE_STATE_DIR:-$HOME/.local/state/orchestrate}
mark=$state/gate-refused-$id
# Markers only matter while an agent runs; prune ones older than a day so they never pile up.
find "$state" -maxdepth 1 -name 'gate-refused-*' -mtime +0 -delete 2>/dev/null
[ -e "$mark" ] && exit 0
msg=$(printf '%s' "$in" | jq -r '.tool_input.message // empty')
case "$role" in
  worker) want='STATUS: (DONE|BLOCKED|FAILED)'; fmt='STATUS: DONE | BLOCKED | FAILED, then CHANGED, CHECK, NOTES' ;;
  researcher) want='ANSWER:'; fmt='ANSWER:, then FACTS, VERSIONS, FAILURE MODES, UNVERIFIED' ;;
  inspector) want='FACTS:'; fmt='FACTS:, then NOT WARM, COULD NOT CHECK' ;;
  *)      want='VERDICT: (PASS|FAIL)';          fmt='VERDICT: PASS | FAIL, then the rest of your format' ;;
esac
if ! printf '%s' "$msg" | command grep -qE "^[[:space:]]*(\*\*)?${want}"; then
  mkdir -p "${mark%/*}" 2>/dev/null && : > "$mark" 2>/dev/null || exit 0   # no marker, no refusal: never lock an agent out
  jq -n --arg r "agent-report-gate ($role): your report has no line starting with ${want//|/ or }. Re-send the whole report once in your file's format, starting with ${fmt}. This is the only refusal; the next hand-back is always delivered." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
