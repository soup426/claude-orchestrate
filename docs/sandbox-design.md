# Design: run subagent Bash commands in a bubblewrap sandbox

Status: built for the five read-only roles (`hooks/sandbox_wrap.py`, `tests/test_sandbox.sh`); the worker is not
sandboxed. See "What was built" at the end for where the build differs from this proposal. Written 2026-11-24 after an independent critique found that the Bash guard infers writes,
runners and network use from command text: about 9 of 83 refusals in five real sessions were clearly right, and one
verifier got past the guard with a rewritten import. Every new allowance has cost 2 to 4 security review rounds.

## Idea

The agent Bash guard stops guessing. Its PreToolUse hook returns `permissionDecision: "allow"` with an `updatedInput`
whose command is the original wrapped in the memory cap and a sandbox:

```
systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- \
  bwrap --die-with-parent --new-session --unshare-pid [--unshare-net] \
    --ro-bind / / --ro-bind <user-owned copy of /etc/ssh> /etc/ssh \
    --dev /dev --proc /proc --tmpfs /tmp --tmpfs "$XDG_RUNTIME_DIR" \
    --ro-bind /dev/null /run/docker.sock --ro-bind /dev/null /run/dbus/system_bus_socket \
    --unsetenv DBUS_SESSION_BUS_ADDRESS --unsetenv SSH_AUTH_SOCK \
    --bind <scratchpad> <scratchpad> [--bind <repo> <repo>] \
    -- bash -c '<original command>'
```

The table is the original proposal; "What was built" below is what shipped (the worker is not sandboxed, and the researcher, inspector and verifier share the host network).

| Role | Writable | Network |
|---|---|---|
| worker | its repo, its scratchpad | off by default; on when the brief says so (package installs) |
| reviewer, security, researcher | scratchpad | off (researcher keeps WebFetch, which is not Bash) |
| inspector, verifier | scratchpad | off: ssh still works through masters the planner opened |

"Read-only" and "capped" then hold for whatever the command runs (scripts, loops, interpreters), not only for what
its text shows. The guard keeps only what text can judge well: git commands that move the tree, the serial port,
package installs, and the remote half of ssh (`inspector_guard.py`, since the sandbox cannot see inside a host).

## Verified on this machine (bubblewrap 0.13.1, systemd 262, Claude Code 2.1.330)

- A write to the repo, and to a separate mount under `/home`, fails with "Read-only file system"; the scratchpad bind
  is writable.
- With `$XDG_RUNTIME_DIR` as an empty tmpfs: the user bus and `systemd-run --user` both fail to connect (so code
  cannot start a unit outside the sandbox).
- With `/dev/null` over the sockets, `docker ps` and the system bus fail to connect. Without that, both stay
  reachable under `--ro-bind / /`.
- `--unshare-net`: `curl` fails. `ssh <host>` through an existing ControlMaster socket works, and a direct
  connection fails with "Network is unreachable". So a sandboxed agent reaches only hosts the planner warmed.
- The command runs in `orchestrate.slice` (cgroup shown inside), so the memory cap covers everything it starts.
- `sudo` fails (no-new-privileges).
- ssh refuses root-owned config seen through the user namespace ("Bad owner or permissions" on
  `/etc/ssh/ssh_config.d/*`, which shows up as owned by nobody). Binding a user-owned copy made with `cp -rL /etc/ssh`
  fixes it.

## Known failure modes (from the research report; sources in the session notes)

- Auto mode can refuse or prompt on a rewritten call unless the hook returns an explicit allow
  (anthropics/claude-code #109300, #110847; #109145 still prompted for one compound command). Test with real
  compound commands.
- If two PreToolUse hooks on one call both return `updatedInput`, the last to finish wins. The other Bash hooks
  (guest-destroy-ask, the cap gate) must never return one.
- A hook that times out or crashes lets the original call through unless the hook sets `"onFailure": "block"`.
- Quoting: the original command must survive one more `bash -c` level; pass it through `printf %q` or an env var.
- `$XDG_RUNTIME_DIR` also holds gpg-agent, the keyring, the Wayland socket and audio. Inside the sandbox they are
  gone, which is intended for agents, but signing commits (`git commit -S`) would fail in a worker.
- Claude Code's own sandbox (`sandbox.enabled`) is session-wide and proxies the network, which blocks plain ssh, so
  it cannot replace this per role. Do not enable both: nested bwrap needs weaker settings.

## Rollout

1. Prototype the wrapper as `hooks/sandbox_wrap.py` with tests that run real commands (writes, sockets, network,
   ssh via a test master on localhost, quoting of nasty commands).
2. One live run with the reviewer role only, in a toy repo, checking the transcript for refusals and prompts.
3. Then the other read-only roles, then the worker.
4. Only after a few real runs: delete the guard's write inference (`drop_scratch`, the redirect and runner lists).

## Open questions

- Whether `updatedInput` from a subagent's frontmatter hook works end to end on this version (evidence so far is a
  bug report that used it, not a test).
- What else under `$XDG_RUNTIME_DIR` a worker legitimately needs.
- Whether to keep `--unshare-net` for the worker by default (it blocks `pip install` and `npm install`).

## What was built (2026-11-24)

- The hook lives in `settings.json`, not in agent frontmatter, and picks the role from `agent_type` in the hook
  input. `updatedInput` from a settings-level PreToolUse hook works in subagents on Claude Code 2.1.330 in auto mode
  (first open question: answered for settings hooks, not tested for frontmatter hooks).
- Roles: reviewer and security have no network; researcher, inspector and verifier share the host network (the
  inspector's allow-list includes local `curl` and `nc -z`). The worker and unknown agent types pass through.
- The inspector's whole command goes through `inspector_guard.py --require-check` before it is wrapped. A verifier
  command sees the ssh master sockets only when it passes the same check.
- The memory cap is part of the rewrite, so read-only agents no longer type it. Claude Code's
  `CLAUDE_CODE_TOOL_MEMORY_LIMIT` was tried as a replacement for the typed cap and rejected: one cgroup is shared
  by all sessions, and with no swap limit a 1.5G allocation under a 1G limit was swapped, not killed.
- The settings entry is a shell shim that only starts Python when the input has an `agent_id`, and denies if the
  script fails, so a broken hook can block subagent commands but never the main session.
- One live smoke run (`scripts/smoke.sh`): three reviewers ran 6 sandboxed commands with 0 refusals; the same task
  on the old guard gave 8 false refusals in one reviewer.
- Not done: a worker sandbox (the other two open questions stay open), and a live ssh test of the inspector and
  verifier paths against real hosts (covered only by `tests/test_sandbox.sh` with fake sockets).
- Limit of the three roles that keep the host network: abstract unix sockets (for example an X11 socket) stay
  reachable, and readable files such as ssh keys can be sent out. Only reviewer and security are cut off.
- Added after the first release: the environment inside the sandbox is an allowlist (`env -i` in front of the whole command, since `bwrap --clearenv` leaves the old values in `/proc/1/environ`; kept: `PATH`,
  `HOME`, locale, `TERM`, `XDG_RUNTIME_DIR`, `VIRTUAL_ENV`, and proxy and CA variables for the roles with network).
  If a tool an agent needs depends on another variable, add it to `ENV` in `hooks/sandbox_wrap.py`.
