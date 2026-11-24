# Orchestrate: special cases

Loaded by the orchestrate skill only when one of these applies. G is the run's state directory, R the repo.

**No git repo.** Say so in the go message. After the go, snapshot the tree into `G/base/` with `cp -a` (leave out `.git`, `.venv`, `node_modules` and build output). Wherever the skill says `git diff BASE`, use `diff -ruN -x .git -x .venv -x node_modules -x build G/base <dir>` (`diff -rq` for status). Reviewers accept a snapshot dir in place of BASE. Delete `G/base` before the final report.

**A file two tasks must both change.** Run them one after the other. Once the first is done, save `git -C <R> diff BASE -- <file> > G/pre-<name>-after-<first task>.patch` (never overwrite the user's `pre-<name>` file) and give it to the second task's reviewer. For an untracked dirty file, `cp` it to `G/pre-<name>.orig`. `<name>` is the repo-relative path with every `/` replaced by `-`.

**Test data standing in for a live system** (log lines, API responses, event names). First query the values the system really produces (a database read, a log sample, the inspector for fixed questions) and put them in the brief's Context. The brief says any line using an unobserved value is marked `# synthetic (unobserved value)` and any finding resting on one must say so. Replace real hostnames, addresses, usernames and secrets before they go into fixtures.

**A test for an unbounded read or allocation.** It must fail cheaply: fake or record the risky call (a size cap, a mock source) instead of reading `/dev/zero` or a huge input for real.

**A command that rewrites build config** (`idf.py set-target`, `menuconfig`, `pio init`). It runs in a scratch copy, never the shared tree: read `build-config-copies.md` before you brief the task, list the copy in the ledger, and delete it before the final report.

**Hardware.** Device checks are yours alone, after the code is integrated, and are named in the task table with their steps (stopping the service that holds the serial port, flashing, live probes). The serial port is exclusive: stop the service holding it, flash, capture the boot log, run the probes, start the service again. Never let two flashes or monitors overlap. A failed device check is a fix round for the owning task; after any edit made because of it, send a reviewer over that edit, then reflash.

**Large reviews.** Split a review over about 1000 changed lines by code area, one reviewer each. A single file over about 800 lines gets its own reviewer.

**Audit.** When the run created a new repo or a new module of about 300 lines or more, or the user asks for an audit, send one more reviewer with `Mode: audit` over those files after the task reviews pass. Its critical and important findings get a fix round like any FAIL; minor ones go in the report.

**A Check that cannot finish in 10 minutes** (the Bash maximum). Narrow or split it for the worker. The long suite is your own capped `run_in_background` run after the workers are done.

**Tests the planner wrote.** A worker must not edit them. The reviewer reports any edit to a read-only test under SCOPE, and `git -C <R> diff -- <test files>` shows it; restore the file and treat it as a FAIL.

**A server left running.** Before the report, `ss -ltnp` and stop any server still listening on a port a verifier's brief named: find it by that port, confirm with `/proc/<pid>/cmdline`, kill that pid, never `pkill -f`.
