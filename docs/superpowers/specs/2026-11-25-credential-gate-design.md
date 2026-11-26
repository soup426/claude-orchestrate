# Credential gate (short design, 2026-11-25)

**Why.** Literal credentials keep landing in Bash commands: since 11-20, 41 distinct commands held a real-looking API
key header, git token, Discord webhook URL or Kuma push token, usually copied from earlier output. A token in a
command is in the transcript before any hook runs, so a PreToolUse check cannot unsee it; what it can do is stop the
command from sending the token and make the next attempt read it from its file.

**Goal.** One PreToolUse hook on Bash, main session and subagents, that refuses a command holding a literal credential
and says how to pass it from its file instead. Non-goals: scrubbing command output (it would change every command),
catching every secret shape (the change-window redactor over-matches on purpose; here a false match costs a refusal).
Anti-goal: new permission prompts. It refuses, it never asks.

**Approaches.** (a) Refuse with a nudge, once per command: chosen, the same pattern as the cap gate, no lockout.
(b) Pipe output through a redactor via `updatedInput`: rejected for now, it changes every command's output and exit
handling. (c) Ask the user: rejected, the user wants fewer prompts.

**Design.** `hooks/credential_gate.py`, run as `python3 -I`. A literal value is 10 or more of `[A-Za-z0-9_.-]` with
at least one letter and one digit; anything starting with `$`, `<` or `*` is not literal. It matches:
- a URL path segment after `/push/`, `/webhook(s)/[id/]` or `/hooks/` (Kuma, Discord, n8n);
- a header value after `Authorization: Bearer|Token|Basic`, `X-Api-Key:`, `Api-Key:` or `Private-Token:`.

On a match it denies once per (session, command hash) with a reason that names the kind but never the value; the same
command retried passes, so a fake test value is never locked out. Marker files live in
`~/.local/state/orchestrate/cred-gate-*` and are pruned after a day. Any error allows (it is a nudge).
Tests: `tests/test_credential_gate.sh`, built from the replayed command shapes (the fake test-fixture case included).
