# Contributing

- Run `bash tests/run.sh` before opening a pull request. It needs bash, jq and python3, and no systemd session.
- A change to `hooks/agent-bash-guard.sh` needs a case in `tests/test_guard.sh` for what it now allows or denies, including a nearby case it must still get right.
- Keep the agent files and skills in plain ASCII punctuation: no em-dashes (use colons, commas or parentheses), and no paths, host names or other details of your own setup.
- Keep changes small and say in the pull request what you ran.

By contributing you agree your work is licensed under Apache-2.0 (see `LICENSE`).
