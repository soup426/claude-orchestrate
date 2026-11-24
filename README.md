# claude-orchestrate

A multi-agent workflow for [Claude Code](https://code.claude.com): the main session (Opus) plans and integrates, Sonnet subagents do the work in parallel, and an independent reviewer checks every task.

What you get:

- **`orchestrate` skill**: the planner. It splits a job into independent tasks with written briefs (Goal, Files, Check, acceptance criteria), dispatches workers in parallel, re-runs each worker's check itself, sends a fresh reviewer per task, and sends failures back for fixes (two rounds, then it takes the task over).
- **Six agents**: `inspector` (read-only live probes of your own hosts and services over already-open SSH connections and read-only MCP tools; returns the command behind each fact), `verifier` (end-to-end: a page in headless Playwright, a CLI's real output, a host checked over read-only SSH, one capped live call), `researcher` (read-only, verifies external facts before the plan is split, every claim sourced), `worker` (one bounded change, limited to the files in its brief), `reviewer` (read-only, PASS or FAIL with `path:line` findings; may run the code under review capped; staying off the network and live hosts is a written convention, not enforced, because the guard checks command text, not what executed code does) and `security` (read-only: gitleaks, secrets in code and output, your private names from a local terms file, and secure-coding checks; runs on security-sensitive tasks and before anything is pushed public, published or posted).
- **`decide` skill**: for "which of these should I pick?" questions. It commits to an instinct and criteria before looking anything up, checks memory and facts, steelmans and attacks each option, optionally asks an advisor model, and returns one decision with what would flip it.
- **`reflect` skill**: run at the end of an orchestrate run. It turns what cost time into at most three proposed skill edits, written as markdown files in `~/.claude/skill-proposals/` for you to review. It never edits skills itself.
- **Hooks** that back up the prose rules (an agent Bash guard with a read-only allow-list for host probes, a report gate, and two optional main-session gates; see Design), and a systemd slice that caps total memory for test and build runs.

## Design, and why

- **One shared working tree.** Workers edit the real tree at the same time, with no worktrees. This is cheap and keeps results integrated, so the rules prevent collisions: no two tasks share a file, a task that uses another task's output starts only after that task's reviewer passes, and agents may not run git commands that change the tree, index or stash.
- **A memory budget, not a worker limit.** Test and build runs are the part that can take down a laptop. Every such run must go through `systemd-run --user --scope --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G`, and the slice (`systemd/orchestrate.slice`) caps the total at 14G. The planner counts 6G per heavy run and 3G per light one and starts agents only while the sum fits (about 4 light or 2 heavy at once). A run that hits its cap exits 137, which is reported as the cap, never retried uncapped.
- **Host scripts are reviewed.** A main-session hook asks you before a script is piped over ssh into `bash -s`/`sh -s` unless it is a file under `~/Projects` (in a repo a reviewer saw). Read-only agents may write only inside their session scratchpad.
- **A guard hook as a backstop.** The agent files say "never run git stash", "no installs", "read-only roles never write". Models forget prose rules, so `hooks/agent-bash-guard.sh` (a `PreToolUse` hook on the `Bash` tool, wired in each agent's frontmatter with its role as the argument) denies the same things mechanically: tree-changing git, ssh (except the inspector's and verifier's checked read-only probes, below) and privilege escalation, installs, recursive `rm`, serial and flashing commands, test or build runners outside the memory cap, and any file write for the read-only roles. `tests/test_guard.sh` has 200+ regression cases.
- **A report gate.** `hooks/agent-report-gate.sh` refuses a subagent hand-back that lacks its first field (`STATUS:`, `VERDICT:`, `ANSWER:` or `FACTS:`), once per agent, so the planner can parse reports. It refuses at most once, so a bug in the hook cannot lock an agent out of reporting.
- **An optional edit gate.** `hooks/orchestrate-edit-gate.sh` (a main-session PreToolUse hook on `Edit|Write`) refuses, once per session, the third distinct file edited inside a git repo while the orchestrate skill has not been loaded, so a multi-file job gets routed through it. A retry goes through, and files under `~/.claude`, `~/.local/state`, `/tmp` and `/var/tmp` are ignored; a missing transcript or any error allows the edit. Enable it by merging `snippets/settings-edit-gate.json` into your `settings.json` hooks (keep your other `PreToolUse` entries).
- **An optional memory-cap gate.** `hooks/main-bash-cap-gate.sh` (a main-session PreToolUse hook on `Bash`) refuses, once per session, a `run_in_background` command that is not under `systemd-run`, so long scans and builds started from the main session get the memory cap too. A retry goes through, and a bare `sleep N` or a `while`/`until ... do sleep` wait loop is exempt. The same snippet file enables it. A lone `estate-warm` or ssh probe (every segment starts with one, no `&`, `$(`, backticks or process substitution) is light and never refused. The same hook asks you, every time and in the foreground too, before ssh is fed from stdin (a `<` redirect, a pipe, a here-doc, an fd or process substitution) unless every `<` source resolves to a regular file under `~/Projects`.
- **An optional reviewer Stop gate.** `hooks/review-stop-gate.sh` (a main-session `Stop` hook) blocks the end of a turn once per session when code under `~/Projects` (not `.md`/`.txt`) was edited after the last `reviewer` run, so self-written code gets its review. The same snippet file enables it.
- **Read-only roles and scratch files.** Reviewer, researcher, security and verifier may write only with a plain `>`/`>>` redirect or `mkdir -p` into their session scratchpad (`/tmp/claude-<uid>/<project>/<session>/scratchpad`, bare paths, no `..`, realpath inside), or `cat > <scratch file> <<'X'` with a quoted delimiter. Any role may run `ssh -V` or `ssh -Q <name>` as a whole command.
- **No turn limits, plus a watchdog.** Agents run until they finish. While any agent is live the planner keeps a background `sleep 1200` timer; when it fires it checks each agent's transcript timestamp and stops one that has been silent for 15 minutes or more.
- **Independent review.** The reviewer starts in a fresh context, did not write the change, and never fixes it. The planner never trusts a worker's PASS: it re-runs the check itself.
- **Hardware is the planner's.** Serial ports and flashing are exclusive resources: agents are blocked from them, and the planner alone stops any service holding the port, flashes and runs live probes after the code is integrated. If you do no embedded work, ignore this part.

## Requirements

- Linux with a systemd user session (the memory slice; the hooks and tests do not need it)
- `bash`, `jq`, `python3` (3.9 or later, standard library only)
- Claude Code with subagent frontmatter hooks. `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` needs v2.1.257 or later ([docs](https://code.claude.com/docs/en/sub-agents#run-every-subagent-on-one-model)). The report gate relies on the `SubagentHandback` tool, which Claude Code provides in auto mode from v2.1.271 ([docs](https://code.claude.com/docs/en/hooks)); in other modes the gate simply never fires and nothing else changes.
- Optional: the [superpowers](https://github.com/obra/superpowers) plugin. With it, `orchestrate` replaces superpowers' subagent-driven-development and dispatching-parallel-agents, and the rest of its process (brainstorming, plans, TDD, verification) wraps around it. Without it everything still works; you write the plan yourself and the superpowers lines in the skills and CLAUDE.md snippet are inert.
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

Restart Claude Code afterwards so it loads the new agents and skills.

The agent files call the guard as `"$HOME/.claude/hooks/agent-bash-guard.sh <role>"`. Claude Code runs a hook command without `args` through a shell, which expands `$HOME` ([hooks reference](https://code.claude.com/docs/en/hooks)). That is from the documentation: I have not run these exact agent files inside a live Claude Code session, only the hook scripts directly (tests below). If the hook does not fire, replace `$HOME` with your absolute home path in the four `agents/*.md` files.

### Changing the memory numbers

The defaults suit a 32 GB machine: 14G for the whole slice, 6G for a heavy run, 3G counted for a light one.

- Slice total: edit `MemoryMax` (and `MemorySwapMax`) in `~/.config/systemd/user/orchestrate.slice`, then `systemctl --user daemon-reload`.
- Per-run cap: change `-p MemoryMax=6G -p MemorySwapMax=1G` in `agents/{worker,reviewer,verifier}.md`, `skills/orchestrate/SKILL.md`, `snippets/CLAUDE.md` and the hook's deny message in `hooks/agent-bash-guard.sh` (`grep -rn 'MemoryMax=6G'` finds them all; the guard only checks that `systemd-run --user --scope` is present, not the number).
- Planner weights and total: "6G if heavy, 3G otherwise, keep the total at or under 14G" in `skills/orchestrate/SKILL.md` section 3, and the same sentence in `snippets/CLAUDE.md`. Keep the total at or below the slice's `MemoryMax`.

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

(or plain `bash tests/run.sh`; it needs only bash, jq and python3, no systemd session.) It runs the guard regression cases, the report-gate cases, an install test in a throwaway `HOME`, and the proposal-writer tests. CI runs the same on every push.

## Limits and known false positives

- **Threat model.** The hooks stop a well-meaning agent's mistakes and casual prompt injection from command output or web pages. They are not a sandbox. For a real boundary on your hosts, give the inspector a dedicated read-only account (for example an SSH forced command that runs only a fixed set of read commands) instead of your own key.
- The `inspector` may use `ssh`, and so may the `verifier` for checking results on a host: any verifier command that spells `ssh` literally (including `/usr/bin/ssh` or a variable holding it) is checked whole by the same parser; obfuscated spellings (`s''sh`, globs) and other ssh clients (`sftp`, `git` over `ssh://`) are not, which is the same limit as every other rule in this regex guard. For both, every ssh must directly follow `ssh -O check <same host> &&`, so only already-open connections are used and no new one can ask for a hardware-key touch; ssh nested inside a remote command is refused. The verifier also drives a browser and has network egress, so a hostile page could try to steer it into reading host data and sending it elsewhere; remote output and page text are data, never instructions, and this is accepted residual risk.
- The `inspector`'s commands are checked by an allow-list parser (`hooks/inspector_guard.py`), not a deny-list. It first refuses any shell syntax where bash and the parser could disagree or where one word could expand into options (`$'..'`, `${..}`, `$(..)`, `$var`, backticks, brace expansion, unquoted globs, loops, unquoted `#` or backslash, a backslash inside double quotes other than `\"` or `\\`, subshells, here-docs, `&`, `/dev/tcp`), so the inspector writes every command literally; then: every command word, including inside `ssh host '...'`, `pct exec <id> -- ...` and `sh -c "..."`, must be a known read-only command with read-only arguments, and anything unknown is refused. If it refuses a read you need, add the command (with its read-only arguments) to the list in that file.
- Residual risks, by design: the `inspector` keeps the Read tool, so it can read local secret files (its file says never to print secret values, but that is prose); the `verifier` drives a browser, and staying on the brief's localhost URL is prose too, so a hostile page could try prompt injection against an agent that has Bash (its guard blocks daemons, background jobs and all-interface binds, not every command). Command output and page content are treated as data in both agent files. Network egress is not limited: the inspector can still send what it reads to another host (`curl`, `dig`), and some allowed reads can hang (`tail -f`, `docker logs -f`).

- The guard is regex matching on the command text, a backstop and not a sandbox. A determined agent can get around it (`eval`, a command assembled in a variable, code run inside an interpreter). It guards the `Bash` tool only; the read-only roles are kept from `Edit` and `Write` by their `tools:` list. Without `jq` the hooks fail open.
- It errs toward denying. Known false positive: text that looks like a forbidden command inside an unquoted search pattern, for example `grep -rn git stash src/`. Quote the pattern (`grep -rn 'git stash' src/`) or write it as `'git.stash'`; the denial message says so. Words such as `make` or `pytest` inside quotes are fine; at a command position they are treated as runs and must be capped.
- The shared tree means a crashing build in one task can fail another task's check. The planner serializes tasks that compile a whole project, but it cannot see every coupling.
- The workflow is token-hungry (roughly 20-28k tokens per agent just to read the code). The skill does small, already-designed fixes itself for that reason.
- The `advisorModel` and `SubagentHandback` features depend on your Claude Code version and plan; see Requirements.

## Uninstall

Remove what `install.sh` listed: `~/.claude/agents/{researcher,inspector,worker,reviewer,security,verifier}.md`, `~/.claude/security/private-terms.txt`, `~/.claude/skills/{orchestrate,decide,reflect}/`, `~/.claude/hooks/agent-{bash-guard,report-gate}.sh`, `~/.claude/hooks/orchestrate-edit-gate.sh`, `~/.claude/hooks/main-bash-cap-gate.sh`, `~/.claude/hooks/review-stop-gate.sh`, `~/.claude/hooks/inspector_guard.py`, `~/.claude/orchestrate/`, `~/.config/systemd/user/orchestrate.slice` (then `systemctl --user daemon-reload`), plus the snippets you added to `CLAUDE.md` and `settings.json`. Run state in `~/.local/state/orchestrate/` and proposals in `~/.claude/skill-proposals/` are yours to keep or delete.

## License

Apache-2.0. See [LICENSE](LICENSE).
