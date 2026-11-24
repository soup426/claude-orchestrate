# Security policy

Please report vulnerabilities through GitHub private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a security problem.

What counts: a way to get a command past `hooks/agent-bash-guard.sh` that the agent files forbid and the guard is meant to catch, a flaw in `install.sh` that overwrites or deletes files it should not, or a path traversal in `scripts/write_proposals.py`.

What does not: the guard is a backstop to the prose rules in the agent files, not a sandbox. A determined agent can always find a command shape a regex misses (see "Limits" in the README). Those are welcome as ordinary issues or pull requests with a regression case in `tests/test_guard.sh`.
