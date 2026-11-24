#!/usr/bin/env bash
# Runs every test. None of them needs a systemd session: the guard tests only pipe JSON into the hook.
cd "$(dirname "$0")/.." || exit 2
rc=0
for t in "bash tests/test_sandbox.sh" "bash tests/test_guard.sh" "bash tests/test_gate.sh" "bash tests/test_bash_cap_gate.sh" "bash tests/test_review_stop_gate.sh" "bash tests/test_drift.sh" "bash tests/test_install.sh" "python3 -I tests/test_write_proposals.py"; do
  echo "== $t"
  $t || rc=1
done
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$rc"
