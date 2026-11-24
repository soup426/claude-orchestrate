#!/usr/bin/env python3
"""PreToolUse hook for Bash: run the read-only agents' commands inside a bubblewrap sandbox and the memory cap.

For the reviewer, security, researcher, inspector and verifier agents it returns "allow" with the command rewritten
to run under systemd-run (the cap) and bwrap: the whole disk read-only, a private /tmp, no user bus, docker socket or
ssh agent, no network unless the role needs it, and only this session's scratch directory writable. Read-only then
holds in the kernel for whatever the command starts, so nothing here reads the command text to guess at writes.
The main session, the worker and unknown agent types pass through untouched (exit 0, no output).
The allow skips the permission classifier for these calls, so every error after the role is known is a deny.
Design and probes: docs/sandbox-design.md. Tests: tests/test_sandbox.sh (they run the rewritten commands for real).
"""
import json, os, re, shlex, shutil, subprocess, sys

NET = {"reviewer": False, "security": False, "researcher": True, "inspector": True, "verifier": True}
CAP = "systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- "
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


def socket_dir():
    """Directory holding ssh ControlMaster sockets, or None. Hidden from every role that may not ssh."""
    d = os.environ.get("ORCHESTRATE_SSH_SOCKET_DIR")
    if not d:
        g = subprocess.run(["ssh", "-G", "localhost"], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"^controlpath (/.+)$", g, re.M)
        d = os.path.dirname(m.group(1)) if m else os.path.expanduser("~/.ssh/cm")
    return d if os.path.isdir(d) else None


def ssh_config_copy():
    """ssh refuses /etc/ssh seen through a user namespace (owner shows as nobody), so bind a user-owned copy."""
    dst = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "orchestrate", "etc-ssh")
    if not os.path.isdir(dst):   # shortcut: copied once and never refreshed, delete the directory after editing /etc/ssh
        os.makedirs(dst)
        for name in ("ssh_config", "ssh_config.d", "ssh_known_hosts"):
            src = os.path.join("/etc/ssh", name)
            if os.path.isdir(src):
                shutil.copytree(src, os.path.join(dst, name))
            elif os.path.isfile(src):
                shutil.copy(src, dst)
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
        cmd = ti["command"]
        sid, proj = d["session_id"], os.path.basename(os.path.dirname(d["transcript_path"]))
        if not re.fullmatch(r"[0-9a-f-]{36}", sid) or not re.fullmatch(r"[A-Za-z0-9_.-]+", proj) or proj in (".", ".."):
            raise ValueError("unexpected session id or transcript path")
        scratch = f"/tmp/claude-{os.getuid()}/{proj}/{sid}"   # from the hook input, never from the command text
        os.makedirs(scratch, exist_ok=True)
        ssh_ok = False
        if role == "inspector":
            ssh_ok, why = read_only_probe(cmd)
            if not ssh_ok:
                out("deny", f"sandbox_wrap (inspector): not a read-only probe: {why}")
        elif role == "verifier" and re.search(r"(^|[^\w.-])ssh([^\w-]|$)", cmd):
            ssh_ok, _ = read_only_probe(cmd)   # anything else still runs, but with the master sockets hidden
        b = ["bwrap", "--die-with-parent", "--new-session", "--unshare-pid"]
        if not NET[role]:
            b.append("--unshare-net")
        b += ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]
        run_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        if os.path.isdir(run_dir):
            b += ["--tmpfs", run_dir]                      # user bus, systemd --user, keyring, podman socket
        for sock in ("/run/docker.sock", "/run/dbus/system_bus_socket", "/run/containerd/containerd.sock"):
            if os.path.exists(sock):
                b += ["--ro-bind", "/dev/null", sock]
        b += ["--unsetenv", "DBUS_SESSION_BUS_ADDRESS", "--unsetenv", "SSH_AUTH_SOCK",
              "--setenv", "PYTHONDONTWRITEBYTECODE", "1", "--bind", scratch, scratch]
        socks = socket_dir()
        if ssh_ok:
            b += ["--ro-bind", ssh_config_copy(), "/etc/ssh"]
        elif socks:
            b += ["--tmpfs", socks]
        cap = "" if os.environ.get("ORCHESTRATE_SANDBOX_NO_CAP") else CAP
        new = cap + " ".join(shlex.quote(x) for x in b) + " -- bash -c " + shlex.quote(cmd)
        out("allow", f"sandboxed ({role})", {**ti, "command": new})
    except SystemExit:
        raise
    except Exception as e:
        out("deny", f"sandbox_wrap ({role}): could not build the sandbox, so the command was not run: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
