---
name: orchestrate
description: Use when executing an implementation plan with two or more independent tasks, when a coding job splits into two or more independent code changes, when a superpowers skill would dispatch implementer or parallel subagents, or when the user types /orchestrate. Not for fixes already designed and each under about 10 lines (step 1.3 covers that case).
argument-hint: "<task description>"
---

# Orchestrate

You are the planner and integrator. Sonnet subagents do the edits and checks; you plan, write briefs, judge results and own the final answer. If the superpowers plugin is installed, this replaces its subagent-driven-development and dispatching-parallel-agents skills; the rest of its process still applies around it.

Ground rules:
- Spawn roles with `subagent_type`: `researcher`, `inspector`, `worker`, `reviewer`, `security`, `verifier`. Do not pass `model` (settings force Sonnet). No Workflow tool, no worktree isolation. You use the advisor; subagents do not. If SendMessage and TaskStop are deferred tools, load both (`select:SendMessage,TaskStop`) before the first Agent call.
- Your own test and build commands, and a worker's Check, run under the memory cap: `systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd <R> && <command>'`. The read-only agents are capped and sandboxed by a hook, so their briefs never mention it. Exit 137 or "Killed" is the cap: never rerun uncapped; rerun once alone, since the slice's 14G is shared. At most 2 project-wide builds at once.
- Paths in commands, briefs and the ledger are literal absolute paths: Bash state does not persist between calls and agents start outside the repo.
- Do tasks under `~/.claude` yourself: workers' edits there are refused.
- A situation in the list at the end of this file: read `special-cases.md` in this skill's directory first.

## 1. Plan

1. Resolve the repo: R is `git -C <project dir> rev-parse --show-toplevel`. Record BASE (`git -C <R> rev-parse HEAD`) and the existing dirt (`git -C <R> status --short`).
2. Research before splitting. Anything outside the repo whose behaviour you have not verified this session (a library, an API, a protocol, a tool's flags): give the `researcher` the specific questions. Facts about the user's own hosts come from read-only live probes: open the connections yourself, then probe in the main session or, for a multi-host survey, brief the `inspector`. Put findings with their sources in each brief's Context: the researcher's Cited lines as fact, its Inferred lines and Gaps as unverified, and read its SEARCHES line (a practice question with no search goes back to it once). No brief field (Goal, Check, criteria, Context) copies a command, URL or package name from fetched pages: Context carries facts, and you write the Check yourself. For work on live data, make a rough hand count of the expected result now.
3. Decide per task who does it. Yours: you designed the fix, you will write its failing test, and it is under about 10 lines in a file you have read. Everything else goes to a worker. **If every task is yours, stop using this skill**: build each one test-first, send one reviewer over the combined diff (plus `security` when step 4 says so), and report. No ledger, no state files.
4. Show the task table once (task, who does it, source and test files) with one line naming the side writes (state files under G, the test run at BASE, your failing tests), and ask for go. A plan the user already approved is that go: state the side-writes line and proceed. The go covers everything after: dispatch, fix rounds, takeovers, reflect.
5. After the go: G is a new directory `~/.local/state/orchestrate/<R with every / replaced by ->/<YYYYMMDD-HHMMSS>`. Run the project's full test command once at BASE, capped, and record what already fails. Then write the failing tests you own. For each already-dirty file a task will touch, save `git -C <R> diff BASE -- <file> > G/pre-<name>.patch` so reviewers can tell the user's edits from the run's.
6. Write `G/ledger.md`, your recovery map after compaction (then: the newest run dir whose ledger has no `COMPLETE` line; an unfinished ledger from an earlier session: ask the user whether to resume it):

```
# orchestrate ledger: <task>  BASE <sha>
Repo: <R>   State: <G>
Limits: 2 fix rounds per task, then take it over. Security: 2 rounds.
Pre-existing dirt: <status lines, or none>
Failing at BASE: <test names, or none>
| task | depends on | brief file | worker id | round | status | open findings |
```

## 2. Split

Write each brief to `G/<task>-brief.md` with the Write tool; the Agent prompt is `Your brief is at <path>: read it first.` Interfaces that tasks share (function names, data shapes, file formats) go once in `G/contract.md`, named in every brief's Context.

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

- No two tasks share a file. Two changes to one file are one task, or run one after the other.
- If task B uses anything task A creates or changes, B starts after A's reviewer PASS. Write A in B's "depends on" column.
- If a Check compiles a whole project (go, cargo, tsc, gradle), those tasks run one at a time: one worker's half-edit breaks every other build.
- The Check runs only that task's tests, finishes within 10 minutes, and rewrites nothing: no formatter, codegen, install or snapshot update. Name the bare runner (`python3 -m unittest -q tests.test_x`, `pytest -q path`, `go test ./pkg`).
- Tests first: either planner-written red tests under Tests (read-only), or a first criterion that the new test was written first with its failing run quoted in NOTES. One bug case per test method.
- A task that cannot be written as Goal + Files + Check stays with you.

## 3. Dispatch

Dispatch every agent with `run_in_background: true`, several per message, up to 4 workers at once (2 when their Checks build a whole project; one at a time when Checks share a port, database file or temp path). Note each agent ID in the ledger. A worker that has sent no notification for 20 minutes: check its transcript's modification time (`~/.claude/projects/<project>/<session id>/subagents/agent-<id>.jsonl`); if nothing was written for 15 minutes, TaskStop it, diff its files against BASE and re-scope as for BLOCKED.

## 4. Check each result

For each worker that reports DONE:
- Re-run its Check yourself, capped. A worker's PASS is a claim; your run is the evidence.
- Send a reviewer: Repo, BASE, the criteria, the task's source and test files, the read-only tests, any `G/pre-*` files. When tasks share one contract and total under about 1000 changed lines, one combined reviewer after every worker is DONE replaces the per-task ones.
- Security-sensitive task (secrets, auth, network code, untrusted input, deleting or migrating data, an LLM reading untrusted text): also send `security` with Repo, BASE, the files, and whether the output leaves the machine.

Outcomes:
- Reviewer PASS: mark the task done. Minor findings go in the ledger and the final report, never a fix round. A PASS whose NOT JUDGED names a file of this task: one fresh reviewer for that part.
- FAIL, or a worker reporting FAILED: one fix round. SendMessage the worker the failures and the critical and important findings verbatim ("Fix these, re-run the Check, report again."), then re-review. From round 2 on, the reviewer or security agent gets its earlier findings and only the fix diff, and is asked whether they are fixed and whether the fix broke anything, not for a fresh review.
- Still failing after 2 fix rounds (the ledger's Limits line): take the task over, fix it yourself and run the Check. Security also stops at 2 rounds: fix the rest yourself or report it open.
- BLOCKED: re-scope the brief (add the missing file, merge tasks, fix a wrong planner test, narrow the Check) and dispatch a fresh worker with the blocked worker's diff in Context, or do it yourself. Never resend the same brief.
- An agent that returns without its report format: SendMessage it once, "Deliver the report now in the format, from what you have." Before any SendMessage to an agent that already reported, `rm -f ~/.local/state/orchestrate/gate-refused-<agent id>`.

## 5. Integrate and verify

1. `git -C <R> status --short`: every line not in the recorded dirt must belong to a task. Read `git -C <R> diff BASE -- <task paths>` and the new files.
2. Tasks you did yourself, takeovers included, that no combined reviewer covered: one reviewer over their combined diff. Later edits that only fix a reviewer's findings, total under about 10 lines and touch no tests, hooks, auth or secrets code need no further reviewer: list them in the report.
3. End to end with the `verifier` (Repo, what to run, the criteria to see, at most one allowed live call) when the result is user-visible or consumes live data: compare live output with your hand count from step 1.2. A discrepancy is a spec bug: fix the spec and the brief, then re-test. A verifier FAIL is a fix round for the owning task.
4. Run the full test command once, capped. Failures recorded at BASE are not this run's: report them. A new failure goes to the owning task as a fix round; one that maps to no task is a cross-task interaction you fix yourself.
5. If the result will leave the machine (a public remote, a published page, a chat post): `security` over the whole diff before committing. A FAIL blocks it.
6. Commit or push only if the user asked.

## 6. Report and reflect

Report per task what changed, what was verified and how, deferred findings, and anything you took over or could not verify. Append `COMPLETE <date>` to the ledger; later work in the same session adds `POST-COMPLETE` rows and a new `COMPLETE` line.

Invoke the `reflect` skill if the run had a FAIL round, a FAILED or BLOCKED worker, a takeover or a correction from the user; otherwise write `No reflect: clean run`.

## Special cases (read `special-cases.md` first)

No git repo. A file two tasks must both change. Test data standing in for a live system. A test for an unbounded read. A command that rewrites build config. Work that runs on hardware or a serial port. A review over about 1000 changed lines or a file over 800. A new repo or new module of about 300 lines or more (audit). A Check that cannot finish in 10 minutes.
