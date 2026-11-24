---
name: orchestrate
description: Use when executing an implementation plan with two or more independent tasks, when a coding job splits into two or more independent code changes, when a superpowers skill would dispatch implementer or parallel subagents, or when the user types /orchestrate. Not for fixes already designed and each under about 10 lines (step 1.4 covers that case).
argument-hint: "<task description>"
---

# Orchestrate

You are the planner and integrator. Sonnet subagents do the edits and checks; you plan, write briefs, judge results and own the final answer. If the optional superpowers plugin is installed, this replaces superpowers:subagent-driven-development and superpowers:dispatching-parallel-agents; the rest of the superpowers process (brainstorming, writing-plans, TDD, debugging, verification, finishing a branch) still applies around it. Without superpowers, nothing else changes: you write the plan yourself in step 1 and skip any mention of superpowers below.

## Ground rules

- Every subagent runs on Sonnet: settings.json forces it (CLAUDE_CODE_SUBAGENT_MODEL_FORCE), so do not pass `model` on Agent calls; it is ignored. Spawn the roles with `subagent_type` set to `researcher`, `inspector`, `worker`, `tester`, `reviewer`, `security` or `verifier`. Never `haiku`. No Workflow tool, no `isolation: "worktree"`.
- You use the advisor; subagents are told not to.
- Before the first Agent call of the run (the step-1.3 researcher and inspector included), load SendMessage and TaskStop (`select:SendMessage,TaskStop`) and start the step-3 watchdog.
- A worker's Check must finish within 10 minutes (the Bash maximum). Narrow or split one that would not; a longer suite is your own `run_in_background` run after the workers are done.
- Do tasks whose files are under `~/.claude` (agents, hooks, skills, settings) yourself: workers' edits there are refused as protected paths.
- Every test or build command in the run, yours included, runs under the memory cap: `systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd <R> && <command>'`, with the Bash timeout at 600000 if it may run past 2 minutes. Exit 137 or "Killed" is the cap: never rerun it uncapped. If other capped runs were live at the time, the shared budget may have killed it: rerun it alone once; only a kill when run alone means a memory leak.
- Bash state does not persist between calls. Every path in commands, the ledger and briefs is a literal absolute path, never `$R` or `$G`; expand `~` and `$HOME` yourself.

## 1. Plan

1. Resolve the repo: `git -C <project dir> rev-parse --show-toplevel` gives R. Your session may have started in a non-git parent, so use `git -C <R>` for every git command. Record BASE (`git -C <R> rev-parse HEAD`) and the pre-existing dirt (`git -C <R> status --short`). No git repo at all: say so in the step-1.5 go message; on go, snapshot the tree into `G/base/` with `cp -a` (after `mkdir -p G` in step 1.6, leaving out `.git`, `.venv`, `node_modules` and build output) and use `diff -ruN -x .git -x .venv -x node_modules -x build G/base <dir>` wherever this skill says `git diff BASE` (and `diff -rq` with the same excludes for `git status`) (reviewers accept a snapshot dir). If R is outside the session's working directories, say so before dispatching: workers' edits there may be refused.
2. Runs for this repo live under `~/.local/state/orchestrate/<R with every / replaced by ->/` (outside `.git` and `.claude`, which are protected paths that prompt or get refused). If the newest run dir there has a `ledger.md` whose last line does not start with `COMPLETE`, read it and ask the user whether to resume it or start over (starting over: first `rm -rf` the scratch copies that ledger lists). Otherwise, and when starting over, this run's state dir G is a new subdir named `<YYYYMMDD-HHMMSS>`; never reuse an old run's files.
3. Research before splitting. If the task touches anything outside the repo whose behaviour you have not verified this session (a library or API, a version-specific feature, a protocol, firmware or hardware, a tool's flags), spawn the `researcher` with the specific questions, in parallel with any code search. Skip it for purely internal changes: then reading the code is the research. Put its findings, with their sources, into each brief's Context; turn anything it marks unverified into Out of scope or a question for the user. Hosts the inspector still reports NOT WARM: open the connection again and ask the user for the touch; only if they decline, move those questions to Out of scope. Facts about the user's own hosts and services (configs, versions, API shapes, data) come from read-only live probes, which count as research and beat docs: first open the SSH connections they need yourself (they may need a hardware-key touch from the user: ask for it, do not skip the host), then give fixed probe questions to the `inspector` (it reports the command behind each fact and trimmed raw samples) instead of probing hosts yourself; read those samples and design matching or parsing rules yourself, since the noise in real data is what shapes them. Make a rough hand count of the expected result now, for step 5. Read just enough code to split the work; for a wide search, spawn one Explore agent.
4. Decide per task who does it. Do it yourself when you have designed the fix, will write its failing test, and it is under about 10 lines in a file you have read: a worker would re-read the same code to type the same lines (about 20-28k tokens per agent). Every other task goes to a worker. Mixed runs are fine.
5. Before any change, list the steps once. Show the task table (task, who does it, source and test files), plus one line naming the side writes (state files under G, the full test run at BASE, your failing tests, any scratch copies and their deletion, reflect proposals to ~/.claude/skill-proposals) and, if there are device checks, the hardware steps (stopping the service that holds the serial port, flashing, live probes), and ask for go. If the user already approved this plan (for example from writing-plans), still state the side-writes line in one sentence, then proceed without asking, unless the approved plan did not mention hardware steps you now need: ask for those. That go covers everything after: state files, failing tests, dispatch, fix rounds, takeovers, reflect. Do not ask again for those.
6. After the go:
   - `mkdir -p G`. Run the project's full test command once at BASE, under the cap (`run_in_background` if it may pass 10 minutes), and record which tests already fail (at BASE plus the recorded dirt). Do this before writing any failing tests of your own, so they are not recorded as failing at BASE.
   - If you write failing tests first, copy them with their full paths (`mkdir -p G/tests && cp --parents <absolute test paths> G/tests/`; restore a file from `G/tests/<its absolute path>`) and hash them: `sha256sum <absolute test paths> > G/tests.sha256`. Whenever you later edit one of them, re-copy and re-hash it before the next check.
   - For each already-dirty file a task will touch, save `git -C <R> diff BASE -- <file> > G/pre-<name>.patch`; for an untracked one, `cp` it to `G/pre-<name>.orig`. `<name>` is always the repo-relative path with every `/` replaced by `-`, so same-named files never collide.
7. Write `G/ledger.md`, your recovery map after compaction. After compaction, find G again as the newest run dir under the state path (step 1.2) whose ledger has no `COMPLETE` line, and continue from its table:

```
# orchestrate ledger: <task>  BASE <sha>
Repo: <R>   State: <G>
Pre-existing dirt: <status lines, or none>
Failing at BASE: <test names, or none>
Test hashes: <G>/tests.sha256 (or none)
Scratch copies: <paths, or none>
| task | depends on | heavy | brief file | worker id | round | status | open findings |
```

## 2. Split

Write each delegated brief to `G/<task>-brief.md` ; the Agent prompt is either the same text or, for long briefs, `Your brief is at <path>: read it first.` Subagents start outside the repo, so paths are absolute:

```
Repo: <R>
Goal: <one concrete outcome>
Files: <absolute paths of the source files and new test files this worker may edit>
Tests (read-only): <planner-written test files, absolute paths, or "none">
Check: <only this task's tests, run from Repo; no pipe and no single quotes (it is wrapped in bash -c '...')>
Acceptance criteria:
- <checkable statement>
Out of scope: <what must not change>
Context: <decisions made, signatures other tasks rely on, researched facts with their source, known failure modes, paths to read first>
```

Rules for the split:
- No two tasks share a file. Two changes to one file are one task, or run one after the other; then, once the first is marked done, save `git -C <R> diff BASE -- <file> > G/pre-<name>-after-<first task>.patch` (never overwrite the user's `pre-<name>` file) so the second task's reviewer can tell the first task's edits from its own.
- If task B imports, calls or tests anything task A creates or changes, B starts after A is marked done in the ledger (reviewer PASS), not merely after A's worker reports DONE. Write A in B's "depends on" column, so the order survives compaction.
- If the Check compiles a whole package or project (go, cargo, tsc, pio, gradle), tasks in that unit run one at a time: one worker's half-edit breaks every other build.
- The Check runs only that task's tests, never the whole suite and never other tasks' new tests. It must not rewrite files: no formatter, codegen, install or snapshot-update flag. If the project's test script does any of those, name the bare runner (`python3 -m unittest -q tests.test_x`, `pytest -q path`, `go test ./pkg`, `npx jest --ci path`).
- One bug case per test method: a runner stops a method at its first failed assert, so a red run of a multi-case method proves only its first case.
- A failing test for an unbounded read or allocation bug must fail cheaply: fake or record the risky call (a size cap, a mock source) instead of reading `/dev/zero` or a huge input for real.
- Commands that rewrite build config (`idf.py set-target`, `menuconfig`, `pio init`) run in a scratch copy of the tree at `/var/tmp/orchestrate-copy-<YYYYMMDD-HHMMSS>-<task>` (on disk, since /tmp is often RAM-backed; a safety hook may block `rm -rf` anywhere else, so keep copies only here and never under G; append its path to the ledger's Scratch copies line), never the shared one. You create it, without `.git` (so nothing run inside can move the real HEAD or index) and without build output: `mkdir -p <copy> && tar -C <R> --anchored --exclude=./.git --exclude=./build --exclude=./.pio --exclude=./node_modules --exclude=./.venv --exclude=./target -cf - . | tar -C <copy> -xf -` (anchored, so a nested `src/build/` is kept; a Check that needs `.venv` cannot use a copy). Create it after the task's dependencies are marked done. The worker edits files in R, so that task's Check starts by syncing its Files over, from Repo: `cd <R> && cp -f --parents <repo-relative Files and Tests> <copy>/ && cd <copy> && <build command>` (`--parents` creates missing dirs for new files; a file the task deletes needs an explicit `rm -f <copy>/<file>`); your own re-run of that Check then syncs the same way. Delete the copy with `rm -rf <copy>` after the task. A Check that needs one goes to a worker (testers cannot create files), and you delete the copy after the task (workers cannot run `rm -r`).
- Split any review over about 1000 changed lines by code area, one reviewer each, and give any single file over about 800 lines its own reviewer.
- A task that cannot be written as Goal + Files + Check stays with you.

## 3. Dispatch workers

Agents have no turn limit and a stuck one never sends a notification, so keep one watchdog running while any agent is live (a stuck permission prompt or stalled call hangs a short task too): Bash `sleep 1200` with `run_in_background`. When it fires, check each running agent without interrupting it (a message would make it hand back early): its transcript is `~/.claude/projects/<project>/<session id>/subagents/agent-<agent id>.jsonl` (project and session id are the two path parts before `/scratchpad` in your scratchpad dir); `stat -c %Y` it. Written in the last 15 minutes: it is working, leave it. Silent for 15 minutes or more (longer than the 10-minute Bash maximum, so a long capped test is never mistaken for a hang): TaskStop it, stop any capped run it left behind (`systemctl --user list-units --type=scope --no-legend`, then `systemctl --user status <unit>` to match its Check and `systemctl --user stop <unit>`), diff its task's files against BASE (and its `G/pre-*` files), then re-scope as for BLOCKED. Re-arm the watchdog while agents remain; TaskStop the pending watchdog before step 6. Dispatch every agent with `run_in_background: true`, so completion notifications arrive while you keep working. Tasks whose Checks share a fixed port, database file or temp path run one at a time even when the budget allows more. Start workers while the memory budget allows (in practice: up to 4 light, or 2 heavy alone, or 1 heavy plus 2 light at once), several per message; start the next queued one when a completion notification arrives. Memory budget: count every live capped run, including your own Check re-runs, testers and the step-5 full run, as 6G if heavy (it compiles a project or is known to use over 3G) and 3G otherwise, and keep the total at or under 14G; going over can get every run killed. In practice: at most 2 heavy runs at once, and wait before re-running any Check while 2 heavy workers are live. Mark heavy in the ledger. The researcher does not count; a reviewer counts only if it runs a test; a verifier's server or browser counts as 3G. An exit 137 from several runs at once means the budget was hit: run those tasks one at a time. Note each worker's agent ID in the ledger.

## 4. Check each result

For each worker that reports DONE:
- Re-run its Check yourself (capped; it is narrow and counts toward the memory budget): a worker's PASS is a claim, your run is the evidence. If `G/tests.sha256` exists, run `sha256sum -c G/tests.sha256`; a FAILED line means it edited a read-only test: restore from `G/tests/` and treat it as a FAIL.
- Always send a reviewer. Brief: Repo, BASE, the acceptance criteria, the task's source and test files, the read-only test files, and any `G/pre-*` files for those files. When the tasks share one written contract and their total diff is under about 1000 lines, one combined reviewer over all of them (after every worker is DONE) replaces the per-task reviewers: the risks sit at the seams between modules. Any single file over about 800 lines still gets its own reviewer.
- Send a tester only when it runs something the worker did not (a wider or independent check, a hidden edge-case test), and not for a task whose Check needs a scratch copy (the tester cannot make one).
- Security-sensitive task (tokens, secrets or auth, network code, untrusted input, deleting or migrating data, an LLM reading untrusted text, anything that will be published or posted): also send the `security` agent with Repo, BASE, the task's files, and whether the output leaves the machine. Not for ordinary tasks; it adds a review.

Outcomes:
- Reviewer PASS (and tester PASS, if one ran): mark the task done in the ledger.
- Any FAIL, or a worker that reports FAILED: one fix round. First `rm -f ~/.local/state/orchestrate/gate-refused-<agent id>` so the report gate checks its next report again, then SendMessage the worker its failures and critical/important findings verbatim ("Fix these, re-run the Check, report again."), then re-run the reviewer (and tester). Log the round and open findings in the ledger.
- A hook on each agent refuses a hand-back without its first line (STATUS: for a worker, ANSWER: for the researcher, FACTS: for the inspector, VERDICT: for the rest), so a missing one is rare. A worker that still returns without a STATUS line (cut off, or stopped early): `rm -f` its gate marker as above, then SendMessage it once: "Continue: finish, run the Check, report in the format." That counts as a fix round.
- A reviewer, tester, security or verifier agent that returns without a VERDICT: `rm -f` its gate marker as above, then SendMessage it once: "Stop reading. Deliver the report now from what you have read; list the rest under NOT JUDGED." Not a fix round. If NOT JUDGED lists something that matters, send a fresh reviewer for just that part.
- An agent that runs far longer than its task warrants with no result: the watchdog in step 3 handles it.
- A reviewer PASS whose NOT JUDGED names a file of this task covers only what it judged: send one fresh reviewer for just that part before marking the task done. This and the no-VERDICT case above share one extra reviewer per task; anything still unjudged, or NOT JUDGED items outside the task, go in the final report.
- After 2 fix rounds still failing, take the task over: fix it yourself and run the Check. A takeover counts as a task you did yourself in step 5.
- Worker BLOCKED: re-scope the brief (add the missing file, merge with the task that owns it, or fix a wrong planner test and re-hash it) and dispatch a fresh worker, or do it yourself. Do not resend the same brief. BLOCKED "memory cap" means narrow the Check or run that task alone; BLOCKED "Check too long" means split or narrow the Check. Either way, put the blocked worker's existing edits (its `git diff` for the task's files) into the new brief's Context, so the next worker builds on them instead of redoing or undoing them.
- Minor findings: list them in the ledger and in the final report. They do not trigger a fix round.

## 5. Integrate and verify

1. If `G/tests.sha256` exists, `sha256sum -c` it once more.
2. `git -C <R> status --short`: every line not in the recorded dirt must be inside some task's Files or Tests, or one of your own tasks; investigate any other. Then read `git -C <R> diff BASE -- <task paths>` plus new untracked files, using `G/pre-*` to tell the user's earlier edits from this run's.
3. If you did any tasks yourself (including takeovers) and no combined reviewer has already covered them, send one reviewer over their combined diff: Repo, BASE, the criteria, their source and test files, and any `G/pre-*` files for them. Fix a FAIL yourself.
4. Device checks, if the work runs on hardware: you alone do them, after the code is integrated. The serial port is exclusive: stop any service holding it, flash, capture the boot log and run the live probes, then start the service again. Never let two flashes or monitors overlap. Name these checks in the task table in step 1.5. A failed device check counts as a fix round for the owning task; after any edit made because of it, send a reviewer over that edit, then reflash.
5. End to end, with the `verifier` (Repo, what to run, the criteria to see, at most one allowed live call): passing unit tests is not enough.
   - User-visible output (a web page, a GUI, a CLI's real output): run it once the way the user would and check the changed behaviour is really there.
   - Code that consumes live data (APIs, hosts, devices): run the integrated pipeline once read-only over live data and compare its output with your hand count from step 1.3. Fixture tests only prove your spec; a discrepancy is a spec bug: fix the spec and the brief, then re-test.
   A verifier FAIL counts as a device-check failure.
6. Run the project's full test command once, under the cap (`run_in_background` if it may pass 10 minutes). Failures listed as failing at BASE are not this run's: report them, do not fix them. For a new failure, find the owning task: SendMessage its worker if you did not take it over, otherwise fix it yourself; it counts as a fix round. A new failure that maps to no task's files is a cross-task interaction: fix it yourself and say so. Re-run until it passes or the task has used its 2 rounds, then report it.
7. If the result will leave the machine (pushed to a remote that is or will be public, published as a page, posted to a chat), send the `security` agent over the whole diff (or the whole tree for a first publish) before committing; a FAIL blocks the commit until fixed.
8. Do not commit or push unless the user asked; a request for a git repo, or commits named in the go list, counts as asking. For a new repo, a first commit holding only `.gitignore` is a fine BASE.

## 6. Report and reflect

Report: what changed (per task), what was verified and how, findings that were deferred, and anything you took over or could not verify. `rm -rf` every scratch copy listed in the ledger and `G/base` if you made one, then append a last line `COMPLETE <date>` to the ledger.

Then always invoke the `reflect` skill, every run, including test runs. Zero proposals is a normal result. Writing to the user's proposal queue (`~/.claude/skill-proposals`) is the intended output, not a side effect to avoid: the user reviews that queue by hand.
