#!/usr/bin/env python3
"""PreToolUse hook for Bash, Read, Grep and Glob: run the read-only agents' commands inside a bubblewrap sandbox and
the memory cap, and keep credential files (HIDDEN plus ~/.config/orchestrate/hidden-paths) from them in both.

For the reviewer, security, researcher, inspector, verifier and Explore agents it returns "allow" with the command rewritten
to run under systemd-run (the cap) and bwrap: the whole disk read-only, a private /tmp, no user bus, docker socket or
ssh agent, no network unless the role needs it, and only this session's scratch directory writable. Read-only then
holds in the kernel for whatever the command starts, so nothing here reads the command text to guess at writes.
The main session, the worker and unknown agent types pass through untouched (exit 0, no output).
The allow skips the permission classifier for these calls, so every error after the role is known is a deny.
Design and probes: docs/sandbox-design.md. Tests: tests/test_sandbox.sh (they run the rewritten commands for real).
"""
import json, os, re, shlex, shutil, stat, subprocess, sys, tempfile

NET = {"reviewer": False, "security": False, "researcher": True, "inspector": True, "verifier": True,
       "Explore": False}   # Explore: the built-in read-only search agent, which CLAUDE.md sends read-only reviews to
# Credential files and dirs no sandboxed role reads; the main session and the worker keep them.
HIDDEN = ("~/.claude/.credentials.json", "~/.git-credentials", "~/.netrc", "~/.aws", "~/.azure", "~/.config/gcloud",
          "~/.config/gh", "~/.kube", "~/.docker/config.json", "~/.npmrc", "~/.pypirc")
CAP = "systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- "
ENV = ("PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "XDG_RUNTIME_DIR",
       "VIRTUAL_ENV")
ENV_NET = ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "SSL_CERT_FILE",
           "SSL_CERT_DIR")
HERE = os.path.dirname(os.path.abspath(__file__))


def out(decision, reason, updated=None):
    h = {"hookEventName": "PreToolUse", "permissionDecision": decision, "permissionDecisionReason": reason}
    if updated is not None:
        h["updatedInput"] = updated
    print(json.dumps({"hookSpecificOutput": h}))
    sys.exit(0)


def read_only_probe(cmd):
    """inspector_guard.py judges the whole command: (True, "") or (False, why)."""
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "inspector_guard.py"), "--require-check", cmd],
                       capture_output=True, text=True, timeout=8)
    return r.returncode == 0, (r.stdout + r.stderr).strip()[:300]


def hidden_paths():
    """HIDDEN plus one ~/ or absolute path per line of ~/.config/orchestrate/hidden-paths, resolved (a symlink hides
    its target). A bad line raises, and main() turns that into a deny."""
    paths: list[str] = list(HIDDEN)
    try:
        with open(os.path.expanduser("~/.config/orchestrate/hidden-paths")) as f:
            for line in f:
                p = line.strip()
                if p and not p.startswith("#"):
                    if not p.startswith(("~/", "/")):
                        raise ValueError(f"hidden-paths: {p[:60]!r} is not a ~/ or absolute path")
                    paths.append(p)
    except FileNotFoundError:
        pass
    return [os.path.realpath(os.path.expanduser(p)) for p in paths]


def check_file_tool(tool, ti, cwd):
    """Read, Grep, Glob: deny a path in a hidden one, and for Grep and Glob a search root that holds one.
    These tools run in Claude Code's own process, outside bwrap, so what bwrap masks is refused here as well: keys in
    ~/.ssh and ~/.gnupg, and /proc (another process's environ holds the environment the sandbox strips).
    shortcut: a symlink in the scratchpad (which these roles can write) swapped to a hidden file after this check is
    not caught; upgrade by denying paths that cross a symlink under /tmp/claude-<uid> if that race ever matters.
    Hard links cannot reach a hidden file: the scratchpad is another mount (EXDEV)."""
    # Every path key present is judged, so a harmless file_path cannot stand in for a hidden path.
    roots = [os.path.join(cwd, os.path.expanduser(v)) for v in (ti.get("file_path"), ti.get("path")) if v] or [cwd]
    if tool == "Glob" and ti.get("pattern"):
        pat = os.path.expanduser(ti["pattern"])
        if re.search(r"(^|[/{,])\.\.($|[/},])", pat):   # .. after a wildcard or in braces would escape the root below
            out("deny", "sandbox_wrap: a Glob pattern with a .. segment is refused for subagents; pass path instead")
        if os.path.isabs(pat) or re.search(r"^\s|\\|^[A-Za-z]:|[{,]\s*[/~]", pat):
            # The tool cuts its own search root out of an absolute pattern (dirname, wildcards, trailing slashes);
            # modelling that missed a case five times, so subagents give the directory as path instead. Forms the
            # tool may also read as absolute (a backslash, a drive letter, leading space, an absolute brace
            # alternative) are refused the same way.
            out("deny", "sandbox_wrap: an absolute Glob pattern is refused for subagents; pass the directory as path"
                " and a relative pattern")
        # A relative pattern keeps roots (path, or cwd): rg matches a slashless glob at any depth, so the whole tree under
        # path or cwd is what it can list, and without .. it cannot leave that tree.
    home = os.path.expanduser("~")
    deny = hidden_paths() + [os.path.realpath(os.path.join(home, k)) for k in (".ssh", ".gnupg")] + ["/proc"]
    for r in roots:
        n = os.path.normpath(r)   # /proc/self/... would resolve in this hook's process, not Claude Code's
        p = "/proc" if n == "/proc" or n.startswith("/proc/") else os.path.realpath(r)
        for h in deny:
            if p == h or p.startswith(h + "/") or (tool != "Read" and h.startswith(p.rstrip("/") + "/")):
                out("deny", f"sandbox_wrap: {tool} of {p} is refused: credential files are hidden from subagents")
    sys.exit(0)


def runs_ssh(cmd):
    """True when ssh is a command word: first, or right after ; & | ( ). Mentions (grep ssh, quoted text) are not."""
    try:
        toks = list(shlex.shlex(cmd, posix=True, punctuation_chars=True))
    except ValueError:
        return False   # unbalanced quotes: the sandbox still runs it, just without this hint
    return any(t == "ssh" and (i == 0 or set(toks[i - 1]) <= set(";&|()")) for i, t in enumerate(toks))


def socket_dir():
    """Directory holding ssh ControlMaster sockets, or None. Hidden from every role that may not ssh."""
    d = os.environ.get("ORCHESTRATE_SSH_SOCKET_DIR")
    if not d:
        g = subprocess.run(["ssh", "-G", "localhost"], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"^controlpath (/.+)$", g, re.M)
        d = os.path.dirname(m.group(1)) if m else os.path.expanduser("~/.ssh/cm")
    return d if os.path.isdir(d) else None


def hidden_masters():
    """Open connections no agent may use: each ssh alias listed in ~/.config/orchestrate/ssh-hidden-hosts (one per
    line) is a privileged login to a host that also has a read-only account, reached through another alias."""
    try:
        with open(os.path.expanduser("~/.config/orchestrate/ssh-hidden-hosts")) as f:
            names = f.read().split()
    except FileNotFoundError:
        return []
    found = []
    for n in names:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", n):
            raise ValueError("ssh-hidden-hosts: not a host alias")
        g = subprocess.run(["ssh", "-G", n], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"^controlpath (/.+)$", g, re.M)
        if not m:
            raise ValueError(f"ssh-hidden-hosts: no control path for {n}")
        if os.path.exists(m.group(1)):
            # shortcut: a connection opened while the agent's command runs is not masked, open it before dispatch
            found.append(m.group(1))
    return found


def find_sockets(top, depth):
    """Unix sockets under top. A slow or failing search raises, which denies the call."""
    # shortcut: depth-limited so the hook stays fast, a socket nested deeper stays reachable (README, Limits)
    r = subprocess.run(["find", "-H", top, "-xdev", "-maxdepth", str(depth), "-type", "s"],
                       capture_output=True, text=True, timeout=3)
    return [p for p in r.stdout.split("\n") if p]


def ssh_config_copy():
    """ssh refuses /etc/ssh seen through a user namespace (owner shows as nobody), so bind a user-owned copy."""
    dst = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "orchestrate", "etc-ssh")
    if not os.path.isdir(dst):   # shortcut: copied once and never refreshed, delete the directory after editing /etc/ssh
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        # build beside it, then rename: a parallel agent never sees half a copy
        tmp = tempfile.mkdtemp(dir=os.path.dirname(dst), prefix="etc-ssh.")
        try:
            for name in ("ssh_config", "ssh_config.d", "ssh_known_hosts"):
                src = os.path.join("/etc/ssh", name)
                if os.path.isdir(src):
                    shutil.copytree(src, os.path.join(tmp, name))
                elif os.path.isfile(src):
                    shutil.copy(src, tmp)
            os.chmod(tmp, 0o755)   # mkdtemp makes it 700; keep what the earlier copy had
            os.rename(tmp, dst)
        except OSError:
            if not os.path.isdir(dst):   # not the race another agent won: a real copy error
                raise
        finally:
            shutil.rmtree(tmp, ignore_errors=True)   # gone already after a successful rename
    return dst


def main():
    try:
        d = json.load(sys.stdin)
        role = d.get("agent_type") if d.get("agent_id") else None
    except Exception:
        sys.exit(0)          # not hook input at all: nothing to wrap, and the main session must never be blocked
    if role not in NET:
        sys.exit(0)
    try:
        ti = d["tool_input"]
        if d.get("tool_name") in ("Read", "Grep", "Glob"):
            check_file_tool(d["tool_name"], ti, d.get("cwd") or os.getcwd())
        cmd = ti["command"]
        sid, proj = d["session_id"], os.path.basename(os.path.dirname(d["transcript_path"]))
        if not re.fullmatch(r"[0-9a-f-]{36}", sid) or not re.fullmatch(r"[A-Za-z0-9_.-]+", proj) or proj in (".", ".."):
            raise ValueError("unexpected session id or transcript path")
        base = f"/tmp/claude-{os.getuid()}"
        scratch = f"{base}/{proj}/{sid}"   # from the hook input, never from the command text
        os.makedirs(base, mode=0o700, exist_ok=True)
        st = os.lstat(base)   # before anything is created below it: whoever owns the parent could swap the leaf
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
            raise ValueError(f"{base} is not a private directory of ours")   # someone else pre-created it in /tmp
        os.makedirs(scratch, exist_ok=True)
        if os.path.realpath(scratch) != scratch or os.stat(scratch).st_uid != os.getuid():
            raise ValueError("scratch directory is a symlink or not ours")
        ssh_ok = False
        if role == "inspector":
            ssh_ok, why = read_only_probe(cmd)
            if not ssh_ok:
                out("deny", f"sandbox_wrap (inspector): not a read-only probe: {why}")
        elif role == "verifier" and re.search(r"(^|[^\w.-])ssh([^\w-]|$)", cmd):
            ssh_ok, why = read_only_probe(cmd)   # anything else still runs, but with the master sockets hidden
            if not ssh_ok and runs_ssh(cmd):   # it would only die on "Bad owner or permissions": say why instead
                out("deny", f"sandbox_wrap (verifier): this ssh cannot run here: {why}. ssh works only as a read-only"
                    " probe chained after `ssh -O check <host> &&`; a script that runs ssh itself cannot run in this"
                    " sandbox, so put it under NOT JUDGED with the exact command for the main session to run.")
        b = ["bwrap", "--die-with-parent", "--new-session", "--unshare-pid"]
        if not NET[role]:
            b.append("--unshare-net")
        b += ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]
        run_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        if os.path.isdir(run_dir):
            b += ["--tmpfs", run_dir]                      # user bus, systemd --user, keyring, podman socket
        b += ["--setenv", "PYTHONDONTWRITEBYTECODE", "1", "--bind", scratch, scratch]
        # A read-only bind does not stop connect(), and --unshare-net does not cover path sockets: every daemon
        # socket (docker, system bus, pcscd, app control sockets under $HOME) gets /dev/null bound over it.
        home, socks = os.path.expanduser("~"), socket_dir()
        keys = [d for d in (os.path.join(home, ".ssh"), os.path.join(home, ".gnupg")) if os.path.isdir(d)]
        secrets = [p for p in hidden_paths() if os.path.lexists(p)]
        hidden = ["/tmp", run_dir] + keys + secrets + ([socks] if socks else [])   # masked as a whole below
        if NET[role]:
            hidden.append("/run/systemd/resolve")   # name lookups for the roles that keep the network
        for sock in find_sockets("/run", 3) + find_sockets(home, 5):
            if not any(sock == h or sock.startswith(h + "/") for h in hidden):
                b += ["--ro-bind", "/dev/null", sock]
        for k in keys:
            b += ["--tmpfs", k]                            # private keys: no role gets them, a master socket needs none
        for s in secrets:                                  # credential files: an empty dir, or /dev/null for a file
            b += ["--tmpfs", s] if os.path.isdir(s) else ["--ro-bind", "/dev/null", s]
        in_ssh = bool(socks) and keys[:1] == [os.path.join(home, ".ssh")] and socks.startswith(keys[0] + "/")
        if ssh_ok:
            b += ["--ro-bind", ssh_config_copy(), "/etc/ssh"]
            for name in ("config", "config.d", "known_hosts"):
                p = os.path.join(home, ".ssh", name)
                if os.path.exists(p):
                    b += ["--ro-bind", p, p]
            if in_ssh:
                b += ["--ro-bind", socks, socks]
            for sock in hidden_masters():
                b += ["--ro-bind", "/dev/null", sock]
        elif socks and not in_ssh:
            b += ["--tmpfs", socks]
        cap = "" if os.environ.get("ORCHESTRATE_SANDBOX_NO_CAP") else CAP
        # The environment is an allowlist, applied with `env -i` before bwrap starts: bwrap --clearenv would leave
        # the full environment readable in /proc/1/environ, because bwrap itself is the sandbox's first process.
        # ${V+V="$V"} is expanded by the shell that runs the command: its value, one word, nothing when unset.
        # A proxy URL that carries credentials (user:pass@) is dropped.
        keep = list(ENV) + [v for v in (ENV_NET if NET[role] else ()) if "@" not in os.environ.get(v, "")]
        env = "env -i " + " ".join('${%s+%s="$%s"}' % (v, v, v) for v in keep) + " "
        new = env + cap + " ".join(shlex.quote(x) for x in b) + " -- bash -c " + shlex.quote(cmd)
        out("allow", f"sandboxed ({role})", {**ti, "command": new})
    except SystemExit:
        raise
    except Exception as e:
        out("deny", f"sandbox_wrap ({role}): could not build the sandbox, so the command was not run: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
