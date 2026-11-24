# claude-orchestrate

A multi-agent workflow for [Claude Code](https://code.claude.com): the main session (Opus) plans and integrates, Sonnet subagents do the work in parallel, and an independent reviewer checks every task.

What you get:

- **`orchestrate` skill**: the planner. It splits a job into independent tasks with written briefs (Goal, Files, Check, acceptance criteria), dispatches workers in parallel, re-runs each worker's check itself, sends a fresh reviewer per task, and sends failures back for fixes (two rounds, then it takes the task over).
- **Six agents**: `inspector` (read-only live probes of your own hosts and services over already-open SSH connections and read-only MCP tools; returns the command behind each fact), `verifier` (end-to-end: a page in headless Playwright, a CLI's real output, a host checked over read-only SSH, one capped live call), `researcher` (read-only, verifies external facts before the plan is split, every claim sourced), `worker` (one bounded change, limited to the files in its brief), `reviewer` (read-only, PASS or FAIL with `path:line` findings; may run the code under review, which happens inside a sandbox with no network and a read-only disk) and `security` (read-only: gitleaks, secrets in code and output, your private names from a local terms file, and secure-coding checks; runs on security-sensitive tasks and before anything is pushed public, published or posted).
- **`decide` skill**: for "which of these should I pick?" questions. It commits to an instinct and criteria before looking anything up, checks memory and facts, steelmans and attacks each option, optionally asks an advisor model, and returns one decision with what would flip it.
- **`reflect` skill**: run at the end of an orchestrate run that had a FAIL round, a failed or blocked worker, a takeover or a correction from you. It turns what cost time into at most three proposed skill edits, written as markdown files in `~/.claude/skill-proposals/` for you to review. It never edits skills itself.
- **Hooks** that enforce what prose cannot (a bubblewrap sandbox for the five read-only agents, a read-only allow-list for host probes, a small text guard for the worker, a report gate, and two optional main-session gates: memory cap with a host-write check, and review at stop; see Design), and a systemd slice that caps total memory for test and build runs.

## Design, and why

- **One shared working tree.** Workers edit the real tree at the same time, with no worktrees. This is cheap and keeps results integrated, so the rules prevent collisions: no two tasks share a file, a task that uses another task's output starts only after that task's reviewer passes, and agents may not run git commands that change the tree, index or stash.
- **A memory budget.** Test and build runs are the part that can take down a laptop. Every such run goes through `systemd-run --user --scope --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G`, and the slice (`systemd/orchestrate.slice`) caps the total at 14G. The planner and the worker type that prefix; the read-only agents get it from the sandbox hook. A run that hits its cap exits 137, which is reported as the cap, never retried uncapped. (Claude Code's own `CLAUDE_CODE_TOOL_MEMORY_LIMIT` was tried instead and rejected: on the test machine an over-limit command was swapped, not killed, because that cgroup sets no swap limit.)
- **A sandbox for the read-only agents, not a text filter.** `hooks/sandbox_wrap.py` is a `PreToolUse` hook on `Bash` in `settings.json`. For the reviewer, security, researcher, inspector and verifier agents (it reads `agent_type` from the hook input) it rewrites the command to run under the memory cap inside [bubblewrap](https://github.com/containers/bubblewrap): the whole disk read-only, a private `/tmp`, only the session's scratch directory writable, no user bus, docker socket or ssh agent, no network for the reviewer and security agents, and ssh master sockets hidden from every role that may not ssh. "Read-only" then holds for whatever a command starts (a script, a test suite, an interpreter), which a check on the command text can never promise. The main session and the worker pass through untouched. The hook returns an explicit allow, so these calls skip the permission classifier and the sandbox is the boundary; any error inside the hook denies the call. An earlier version of this repo did the same job with a regex guard and 680 test cases; in five real sessions about 9 of its 83 refusals were right. `docs/sandbox-design.md` has the probes and the limits.
- **A small guard for the worker.** A worker runs arbitrary code by design, so `hooks/agent-bash-guard.sh` (wired in the worker's frontmatter) is a seatbelt for the few things workers share, not a boundary: tree-changing git, ssh and privilege escalation, installs, recursive `rm`, serial and flashing commands, and test or build runners outside the memory cap.
- **A report gate.** `hooks/agent-report-gate.sh` refuses a subagent hand-back that lacks its first field (`STATUS:`, `VERDICT:`, `ANSWER:` or `FACTS:`), once per agent, so the planner can parse reports. It refuses at most once, so a bug in the hook cannot lock an agent out of reporting.
- **An optional memory-cap gate.** `hooks/main-bash-cap-gate.sh` (a main-session PreToolUse hook on `Bash`) refuses, once per command, a `run_in_background` command that is not under `systemd-run`, so long scans and builds started from the main session get the memory cap too. A retry goes through, and a bare `sleep N`, a `while`/`until ... do sleep` wait loop and a lone ssh probe are exempt. Enable it by merging `snippets/settings-gates.json` into your `settings.json` hooks (keep your other entries). The same hook has a host-write check, in the foreground too: for an ssh, scp or rsync command that `inspector_guard.py` does not accept as read-only, it asks you first when code was changed after the last `reviewer` run (`hooks/review_owed.py` reads the transcript). `ssh-copy-id` counts as a host change. Read-only probes never ask. It sees only the command text, so ssh hidden inside `bash -c`, a variable or a local script is not caught, and it does not judge where a script fed to a host came from: "host scripts live in the repo, committed and reviewed" is a CLAUDE.md rule.
- **An optional reviewer Stop gate.** `hooks/review-stop-gate.sh` (a main-session `Stop` hook) blocks the end of a turn when code under `~/Projects`, `~/.claude/hooks` or `~/.claude/agents` (not other `.md`/`.txt`) was changed after the last `reviewer` run, so self-written code gets its review. Changes are Edit/Write calls and Bash writes it can see in the text (`sed -i`, redirects, `tee`, `cp`, `mv`, `install` with a literal path). It blocks again only after a newer change, and never on a re-stop. The same snippet file enables it.
- **No turn limits.** Agents run until they finish. A worker that has sent nothing for 20 minutes gets its transcript timestamp checked, and is stopped if it has been silent for 15.
- **Small jobs skip the machinery.** If the planner keeps every task for itself (each fix already designed and under about 10 lines), the skill tells it to stop there: build test-first, one reviewer, no ledger or state files. Rare situations (no git repo, hardware, build-config commands, very large reviews) live in `skills/orchestrate/special-cases.md` and are read only when they apply.
- **Independent review.** The reviewer starts in a fresh context, did not write the change, and never fixes it. The planner never trusts a worker's PASS: it re-runs the check itself.
- **Hardware is the planner's.** Serial ports and flashing are exclusive resources: agents are blocked from them, and the planner alone stops any service holding the port, flashes and runs live probes after the code is integrated. If you do no embedded work, ignore this part.

## Requirements

- Linux with a systemd user session (the memory slice and the cap the sandbox hook applies)
- [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) with unprivileged user namespaces. Without it the five read-only agents cannot run Bash at all: their commands fail, they are never run unsandboxed. Check with `bwrap --ro-bind / / true`.
- `bash`, `jq`, `python3` (3.9 or later, standard library only)
- Used by the agents when present: `gitleaks` (the security agent's secret scan)
- Claude Code with subagent frontmatter hooks, and `agent_type` in hook input plus `updatedInput` from PreToolUse hooks (tested on v2.1.330 in auto mode). `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` needs v2.1.257 or later ([docs](https://code.claude.com/docs/en/sub-agents#run-every-subagent-on-one-model)). The report gate relies on the `SubagentHandback` tool, which Claude Code provides in auto mode from v2.1.271 ([docs](https://code.claude.com/docs/en/hooks)); in other modes the gate simply never fires and nothing else changes.
- Optional: the [superpowers](https://github.com/obra/superpowers) plugin. With it, `orchestrate` replaces superpowers' subagent-driven-development and dispatching-parallel-agents, and the rest of its process (brainstorming, plans, TDD, verification) wraps around it. Without it everything still works; you write the plan yourself and the superpowers lines in the skills and CLAUDE.md snippet are inert.
- Optional: the [ponytail](https://github.com/DietrichGebert/ponytail) plugin. The reviewer preloads its `ponytail-review` checklist (load, tests, speed, lean code) and follows `ponytail-audit` when a brief says `Mode: audit`; without ponytail the preload is skipped and the reviewer uses its own checklist. Ponytail injects its ruleset into every subagent unless you scope it: `"env": {"PONYTAIL_SUBAGENT_MATCHER": "^worker$"}` in `settings.json` keeps it to the one agent that writes code.
- Optional: an `advisorModel` setting for the `decide` skill's independent check ([docs](https://code.claude.com/docs/en/advisor)). Without one, `decide` skips that step and says so.

## Install

```bash
git clone <this repo> && cd claude-orchestrate
./install.sh
```

`install.sh` copies the agents, skills and hooks into `~/.claude/`, the reflect writer into `~/.claude/orchestrate/`, and the slice into `~/.config/systemd/user/`, then runs `systemctl --user daemon-reload`. It refuses to overwrite a file that already exists and differs (and changes nothing in that case); `--force` backs each such file up as `<name>.bak-<timestamp>` and replaces it. `--no-reload` skips the daemon reload.

It never edits `settings.json` or `CLAUDE.md`. It prints two snippets (also in `snippets/`) for you to add by hand:

1. `snippets/CLAUDE.md`: the routing rules (use `decide` for choices, cap every test run, route plans to `orchestrate`, route research to the `researcher`).
2. `snippets/settings.json`: merge into your `~/.claude/settings.json`.
   - `CLAUDE_CODE_SUBAGENT_MODEL` plus `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` put every subagent on Sonnet and ignore any `model` the planner passes. This is what keeps the `orchestrate` rule "never Haiku" true.
   - `advisorModel` enables the advisor tool for the main session. `fable` is the author's value; run `/advisor` to see what you can use, or omit the key.
   - The `PreToolUse` entry is the sandbox hook. It is required, not optional: the read-only agents have no other Bash guard. Its command is a one-line shell shim that does nothing for the main session (no `agent_id` in the input), so a missing or broken `sandbox_wrap.py` can only ever block subagent commands. If another of your Bash hooks returns `updatedInput`, the last one to finish wins: keep this the only one that does.
   - Optional: `snippets/settings-gates.json` adds the memory-cap gate and the reviewer Stop gate.

Restart Claude Code afterwards so it loads the new agents and skills.

If your ssh `ControlPath` is not what `ssh -G localhost` reports, set `ORCHESTRATE_SSH_SOCKET_DIR` to the directory that holds your master sockets, so the hook can hide it from the agents that may not ssh.

The agent files call their frontmatter hooks as `"$HOME/.claude/hooks/<name>"`. Claude Code runs a hook command without `args` through a shell, which expands `$HOME` ([hooks reference](https://code.claude.com/docs/en/hooks)). The author's live copies use an absolute path instead; if a hook does not fire, do the same.

### Changing the memory numbers

The defaults suit a 32 GB machine: 14G for the whole slice, 6G per capped run.

- Slice total: edit `MemoryMax` (and `MemorySwapMax`) in `~/.config/systemd/user/orchestrate.slice`, then `systemctl --user daemon-reload`.
- Per-run cap: change `-p MemoryMax=6G -p MemorySwapMax=1G` in `hooks/sandbox_wrap.py` (the read-only agents), `agents/worker.md`, `skills/orchestrate/SKILL.md`, `snippets/CLAUDE.md` and the deny messages in `hooks/agent-bash-guard.sh` and `hooks/main-bash-cap-gate.sh` (`grep -rn 'MemoryMax=6G'` finds them all).

### Giving the inspector your read-only MCP tools

`agents/inspector.md` ships with only Read, Grep, Glob, Bash and ToolSearch. If you have MCP servers for your infrastructure (for example Proxmox, NetBox or Grafana), add their read-only tools to its `tools:` line by exact name, such as `mcp__proxmox__get_cluster_resources`. List tools one by one: naming a whole server would also give it that server's write tools. The `verifier` expects the Playwright MCP server (`mcp__playwright__*`) for web pages; without it, it can still check CLI output.

## Usage

Ask Claude Code for a job that splits into independent changes, or type `/orchestrate`:

```
/orchestrate In ./myapp, add a --json flag to the list command (src/cli.py), a matching
formatter (src/format.py) and tests for both. Check the click docs for the exact flag API first.
```

What happens: the planner resolves the repo and records a base commit, sends the `researcher` to verify the click behaviour, shows a task table and asks for one "go", runs your full test suite once at the base to see what already fails, writes a brief per task, and starts workers in parallel. Each worker's check is re-run by the planner and each task gets a reviewer; findings go back to the worker for up to two fix rounds. At the end it runs the full suite, reports what changed and what it could not verify, and runs `reflect`. It does not commit or push unless you ask.

Run state (ledger, briefs, snapshots of your pre-existing edits) lives in `~/.local/state/orchestrate/<repo path>/<timestamp>/`, so an interrupted run can be resumed.

For a choice rather than a change: "I can't decide between X and Y for this, you pick" invokes `decide`.

## Tests

```bash
systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd . && bash tests/run.sh'
```

(or plain `bash tests/run.sh`.) It runs the sandbox tests, the worker-guard and inspector allow-list cases, the gate cases, an install test in a throwaway `HOME`, and the proposal-writer tests. The sandbox tests execute the rewritten commands for real (a write into `$HOME` must fail, the scratch write must land, the network namespace must differ, the docker socket and user bus must be gone); where bubblewrap cannot create a sandbox, as on some CI runners, that suite prints SKIP. CI runs the same on every push.

After installing, `bash scripts/check_drift.sh` compares your `~/.claude` with the repo: a hook that differs or is missing is an error (exit 1), and agents and skills that differ are listed, since your copies may carry private details on purpose. Run it in a SessionStart hook to hear about drift early.

`scripts/smoke.sh <toy repo>` is the live check that unit tests cannot give: one headless Claude Code session on a toy git repo with the prompt in `scripts/smoke-prompt.txt`, then a summary of what the transcript shows (which skills and agents ran, how many subagent commands were sandboxed, every guard or gate refusal). It needs a login and costs a few dollars, so it is not in CI. Run it after changing CLAUDE.md, an agent, a skill or a hook, and compare with the last run.

## Limits and known false positives

- **Threat model.** The sandbox is a real boundary for local writes by the five read-only agents' Bash commands. It also puts `/dev/null` over every unix socket it finds under `/run` and your home directory (docker, the system bus, pcscd, app control sockets), because a read-only disk does not stop a connection to a daemon, and it empties `~/.ssh` and `~/.gnupg` (the roles that may ssh get back only `config`, `config.d`, `known_hosts` and the master sockets, never a private key). It is not a boundary for: other reads (the rest of the disk and the environment variables of the Claude Code process stay readable, so the researcher, inspector and verifier, which keep the network, can send out what they read; credentials kept elsewhere, such as cloud CLI token files, are not hidden), a socket nested more than five directories below your home or created after the command started, abstract sockets and localhost services for the three roles that share the host network, MCP tools (the verifier's browser runs outside the sandbox), the worker (unsandboxed; its guard is a text check), the `Edit` and `Write` tools (kept from read-only roles by their `tools:` list, and for the worker limited to its brief only by prose and the reviewer's scope check), and anything on a remote host. For a real boundary on your hosts, give the inspector a dedicated read-only account (for example an SSH forced command that runs only a fixed set of read commands) instead of your own key.
- The `inspector` may use `ssh`: every one of its commands is checked whole by `hooks/inspector_guard.py` before it runs. The `verifier` may too, for checking results on a host: the ssh master sockets are visible to a verifier command only when that whole command passes the same check, and are hidden from everything else it runs, so a script it starts cannot reach a warmed host. For both, every ssh must directly follow `ssh -O check <same host> &&`, so only already-open connections are used. A new ssh login from any other command has no key to offer: `~/.ssh` is empty, the agent socket is gone and `/dev` has no hardware-key device. Hiding the sockets relies on the hook finding your `ControlPath` directory (see Install); if some `Host` blocks use a different directory outside `~/.ssh`, those sockets stay visible, so keep them all in one place. The verifier also drives a browser and has network egress, so a hostile page could try to steer it; remote output and page text are data, never instructions, and this is accepted residual risk.
- The `inspector`'s commands are checked by an allow-list parser (`hooks/inspector_guard.py`), not a deny-list. It first refuses any shell syntax where bash and the parser could disagree or where one word could expand into options (`$'..'`, `${..}`, `$(..)`, `$var`, backticks, brace expansion, unquoted globs, loops, unquoted `#` or backslash, a backslash inside double quotes other than `\"` or `\\`, subshells, here-docs, `&`, `/dev/tcp`), so the inspector writes every command literally; then: every command word, including inside `ssh host '...'`, `pct exec <id> -- ...` and `sh -c "..."`, must be a known read-only command with read-only arguments, and anything unknown is refused. If it refuses a read you need, add the command (with its read-only arguments) to the list in that file.
- Residual risks, by design: the `inspector` keeps the Read tool, so it can read local secret files (its file says never to print secret values, but that is prose); the `verifier` drives a browser, and staying on the brief's localhost URL is prose too, so a hostile page could try prompt injection against an agent that has Bash (inside the sandbox; binding a test server to loopback only is prose). Command output and page content are treated as data in both agent files. Network egress is not limited for those two: the inspector can still send what it reads to another host (`curl`, `dig`), and some allowed reads can hang (`tail -f`, `docker logs -f`).
- More sandbox limits. Sockets outside `/run` and your home directory (`/var/lib`, `/var/tmp`, `/opt`) and on other filesystems mounted below your home are not masked. If `~/.ssh` is a symlink, the keys stay readable at the link's target. The socket search has a 3 second limit and a socket that disappears between the search and the command makes that one command fail: both fail closed, so a very large or network-mounted home can block the read-only agents. An ssh `ControlPath` must point into a subdirectory of `~/.ssh` or outside it, never at `~/.ssh` itself, or the inspector and verifier lose their connections.
- Inside the sandbox, tools that write caches under `$HOME` (pytest's cache, `__pycache__`, package managers) cannot. Test runs still work; a tool that insists on a writable home fails, and the agent reports that check as not judged.
- The worker's guard is regex matching on the command text, a seatbelt and not a sandbox. A determined agent can get around it (`eval`, a command assembled in a variable, code run inside an interpreter). Without `jq` it fails open.
- It errs toward denying. Known false positives: a here-doc whose body looks like a test run (workers are told to use the Write tool), and text that looks like a forbidden command inside an unquoted search pattern, for example `grep -rn git stash src/`. Quote the pattern (`grep -rn 'git stash' src/`) or write it as `'git.stash'`; the denial message says so. Words such as `make` or `pytest` inside quotes are fine; at a command position they are treated as runs and must be capped.
- The shared tree means a crashing build in one task can fail another task's check. The planner serializes tasks that compile a whole project, but it cannot see every coupling.
- The workflow is token-hungry (roughly 20-28k tokens per agent just to read the code). The skill does small, already-designed fixes itself for that reason.
- The `advisorModel` and `SubagentHandback` features depend on your Claude Code version and plan; see Requirements.

## Uninstall

Remove what `install.sh` listed: `~/.claude/agents/{researcher,inspector,worker,reviewer,security,verifier}.md`, `~/.claude/security/private-terms.txt`, `~/.claude/skills/{orchestrate,decide,reflect}/`, `~/.claude/hooks/agent-{bash-guard,report-gate}.sh`, `~/.claude/hooks/sandbox_wrap.py`, `~/.claude/hooks/main-bash-cap-gate.sh`, `~/.claude/hooks/review-stop-gate.sh`, `~/.claude/hooks/inspector_guard.py`, `~/.claude/hooks/review_owed.py`, `~/.claude/orchestrate/`, `~/.config/systemd/user/orchestrate.slice` (then `systemctl --user daemon-reload`), plus the snippets you added to `CLAUDE.md` and `settings.json`. Run state in `~/.local/state/orchestrate/` and proposals in `~/.claude/skill-proposals/` are yours to keep or delete.

## License

Apache-2.0. See [LICENSE](LICENSE).
