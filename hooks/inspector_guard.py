#!/usr/bin/env python3
"""Allow-list checker for the inspector agent's Bash commands (local and remote).

Usage: inspector_guard.py "<command>"  -> exit 0 and no output if allowed, else prints the reason and exits 1.

Two layers:
1. A strict shell subset. Anything where bash and this parser could disagree is refused before parsing:
   ANSI-C or locale quoting ($'..', $".."), ${..}, $(..), backticks, process substitution, here-docs,
   unquoted # or backslash, case, and backgrounding. Only $? is allowed: a variable could hold an option.
2. Per-command allow-lists: every command word, including inside `ssh host '...'`, `pct exec <id> -- ...`
   and `sh -c '...'`, must be a known read-only command; risky commands also need their verb first and
   only known options (with the options that take a value known), so an option value cannot hide a verb.

Threat model: this stops a well-meaning agent's mistakes and casual prompt injection from command output.
It is not a sandbox. The real boundary is a read-only account on each host (for example a forced command).
Unknown means denied, and any error means denied (the calling hook treats a non-zero exit as deny).
"""
import os
import re
import shlex
import sys

READ = set("""cat head tail ls stat wc grep egrep fgrep zgrep zcat cut tr column jq uptime uname id whoami groups
df du free lsblk findmnt lscpu lspci lsusb netstat ps pgrep lsof getent sha256sum md5sum b2sum diff cmp
readlink realpath dirname basename which type nproc vmstat iostat mpstat dig nslookup host echo true false
cd pwd sleep seq base64 pveversion lsmod""".split())
KEYWORDS = {"!"}  # no loops or conditionals: their variables and words would expand into options
SAFE_DIRS = ("", "/bin", "/usr/bin", "/sbin", "/usr/sbin", "/usr/local/bin")
OK_ENV = {"LC_ALL", "LANG", "LANGUAGE", "TZ", "COLUMNS", "LINES", "TERM", "NO_COLOR"}
SSH_OK_OPTS = {"BatchMode=yes", "ControlMaster=no", "StrictHostKeyChecking=yes", "LogLevel=ERROR", "LogLevel=QUIET"}


REQUIRE_CHECK = False   # --require-check: every non-check ssh must directly follow `ssh -O check <same host> &&`
CTX = {"prev": None, "sep": None}


class Deny(Exception):
    pass


def need(cond, why):
    if not cond:
        raise Deny(why)


def subset(text):
    """Refuse shell syntax outside the subset this parser understands exactly like bash."""
    q = None  # None, "'" or '"'
    i = 0
    while i < len(text):
        c, n = text[i], text[i + 1:i + 2]
        if q == "'":
            if c == "'":
                q = None
        elif q == '"':
            if c == '"':
                q = None
            elif c == "`" or c == "$" and n != "?":
                raise Deny("$ expansion inside double quotes (a variable can hold an option; write the value literally)")
            elif c == "\\":
                need(n in ('"', "\\"), "backslash inside double quotes other than \\\" or \\\\ (bash and the checker would read it differently)")
                i += 1
        else:
            if c in ("'", '"'):
                q = c
            elif c == "$" and n == "?":
                i += 1  # $? (the last exit code) is the one expansion allowed
            elif c == "$":
                raise Deny("$ expansion (a variable or substitution can hold an option or a command; write the value literally)")
            elif c in "{}":
                raise Deny("unquoted { or } (brace expansion can turn one word into options)")
            elif c in "*?[]":
                raise Deny("unquoted glob character (a file name can become an option; quote the pattern)")
            elif c == "`":
                raise Deny("backtick substitution")
            elif c == "#":
                raise Deny("unquoted # (comments are not in the supported shell subset)")
            elif c == "\\":
                raise Deny("unquoted backslash (quote the argument instead)")
            elif c in "<>" and n == "(":
                raise Deny("process substitution")
        i += 1
    need(q is None, "unterminated quote")
    need(not re.search(r"'[<>&|;()]+'|\"[<>&|;()]+\"", text), "a quoted shell operator (it would look like a redirect or separator to the checker)")
    need(not re.search(r"/dev/(tcp|udp)/", text), "/dev/tcp or /dev/udp network redirect")


def parse(args, boolean, valued, positional_verb=True):
    """Split args into (verb, rest): only known options may come before the verb; valued options eat their value."""
    i = 0
    while i < len(args) and args[i].startswith("-") and args[i] != "-":
        o = args[i]
        key = o.split("=", 1)[0]
        if key in valued or (len(o) > 2 and o[1] != "-" and o[:2] in valued):
            i += 1 if ("=" in o or key not in valued) else 2
            continue
        if key in boolean or (re.fullmatch(r"-[A-Za-z]{2,}", o) and all(f"-{ch}" in boolean for ch in o[1:])):
            i += 1
            continue
        raise Deny(f"option {o} is not on the read-only list")
    if not positional_verb:
        return None, args[i:]
    return (args[i] if i < len(args) else None), args[i + 1:]


def only_opts(args, boolean, valued, max_positional=None):
    """Every option known; positionals (including '-' and anything after '--') counted."""
    i, pos = 0, 0
    while i < len(args):
        o = args[i]
        if o == "--":
            pos += len(args) - i - 1
            break
        if o.startswith("-") and o != "-":
            key = o.split("=", 1)[0]
            if key in valued or (len(o) > 2 and o[1] != "-" and o[:2] in valued):
                i += 1 if ("=" in o or key not in valued) else 2
                continue
            if key in boolean or (re.fullmatch(r"-[A-Za-z0-9]{2,}", o) and all(f"-{ch}" in boolean for ch in o[1:])):
                i += 1
                continue
            raise Deny(f"option {o} is not on the read-only list")
        pos += 1
        i += 1
    need(max_positional is None or pos <= max_positional, "too many file arguments (one could be an output file)")


def check_args(cmd, args, depth):
    a = " ".join(args)
    if cmd in READ:
        return
    if cmd == "ssh":
        return check_ssh(args, depth)
    if cmd == "blkid":
        only_opts(args, {"-l", "-p", "-i"}, {"-o", "-s", "-t", "--output", "--match-tag", "--match-token"})
        return
    if cmd in ("sh", "bash", "dash"):
        need(len(args) == 2 and args[0] == "-c", f"{cmd} other than -c '<command>'")
        return check(args[1], depth + 1)
    if cmd == "date":
        only_opts(args, {"-u", "-R", "--utc", "--rfc-email"}, {"-d", "--date", "-I", "--iso-8601"}, max_positional=1)
        need(all(x.startswith(("+", "-")) or (i > 0 and args[i - 1] in ("-d", "--date")) for i, x in enumerate(args)), "date positional other than +FORMAT (it would set the clock)")
        return
    if cmd == "hostname":
        only_opts(args, {"-f", "-s", "-I", "-i", "-A", "-d", "--fqdn", "--short", "--all-ip-addresses", "--ip-address", "--domain"}, set(), max_positional=0)
        return
    if cmd == "pvecm":
        need(args[:1] in (["status"], ["nodes"]) and len(args) == 1, "pvecm other than status/nodes")
        return
    if cmd == "nvidia-smi":
        only_opts(args, {"-q", "-L", "--list-gpus"}, {"--query-gpu", "--query-compute-apps", "--format", "-i", "--id", "-d", "--display"}, max_positional=0)
        return
    if cmd == "ss":
        only_opts(args, set(f"-{c}" for c in "tulnpaxw46seimoHrO0") | {"--tcp", "--udp", "--listening", "--numeric", "--processes", "--all", "--summary", "--extended", "--info", "--no-header"}, set(), max_positional=8)
        need(not re.search(r"(^|\s)-\w*[DK]|--(diag|kill)", a), "ss -D/-K")
        return
    if cmd == "sensors":
        only_opts(args, {"-u", "-A", "-j", "-f"}, set(), max_positional=2)
        return
    if cmd == "uniq":
        only_opts(args, {"-c", "-d", "-u", "-i", "-D", "-z", "--count", "--repeated", "--unique", "--ignore-case"}, {"-f", "-s", "-w", "--skip-fields", "--skip-chars", "--check-chars"}, max_positional=1)
        return
    if cmd == "file":
        only_opts(args, {"-b", "-i", "-L", "-s", "-z", "--mime", "--brief", "--mime-type"}, set())
        return
    if cmd == "yq":
        only_opts(args, {"-r", "-e", "-P", "-C", "-M", "-N"}, {"-o", "--output-format", "-p", "--input-format"}, max_positional=2)
        return
    if cmd == "rg":
        only_opts(args, set(f"-{c}" for c in "nilcwvFSHuxNo") | {"--no-heading", "--hidden", "--files", "--count", "--json", "--files-with-matches", "-uu", "--no-ignore", "--line-number", "--ignore-case", "--fixed-strings", "--word-regexp", "--invert-match"},
                  {"-e", "-g", "-t", "-T", "-A", "-B", "-C", "-m", "--max-count", "--glob", "--type", "--regexp", "--max-depth", "-M", "--max-columns"})
        return
    if cmd == "find":
        valued = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex", "-type", "-xtype", "-maxdepth", "-mindepth",
                  "-mtime", "-mmin", "-atime", "-amin", "-ctime", "-cmin", "-newer", "-size", "-user", "-group", "-uid", "-gid", "-perm", "-links",
                  "-inum", "-samefile", "-printf", "-regextype", "-lname", "-ilname", "-used"}
        boolean = {"-print", "-print0", "-ls", "-o", "-or", "-a", "-and", "-not", "!", "-empty", "-xdev", "-mount", "-follow", "-prune", "-readable",
                   "-writable", "-executable", "-daystart", "-depth", "-nouser", "-nogroup", "-true", "-false", "-L", "-P", "-H", "-quit"}
        i, seen_expr = 0, False
        while i < len(args):
            x = args[i]
            if x in valued:
                seen_expr, i = True, i + 2
                continue
            if x in boolean:
                seen_expr, i = True, i + 1
                continue
            need(not x.startswith("-") and not seen_expr, f"find test or action {x} is not on the read-only list")
            i += 1
        return
    if cmd == "sort":
        only_opts(args, set(f"-{c}" for c in "nrufbdhiMVsgkRz") | {"--numeric-sort", "--reverse", "--unique", "--human-numeric-sort", "--version-sort"}, {"-k", "-t", "--key", "--field-separator"})
        return
    if cmd == "sed":
        scripts = [x for x in args if not x.startswith("-")]
        need(all(x in ("-n", "-E", "-r") for x in args if x.startswith("-")), "sed option other than -n/-E/-r")
        need(scripts and re.fullmatch(r"([0-9]+|\$)(,([0-9]+|\$))?p|/[^/]*/p|[0-9]+q", scripts[0]), "sed other than -n 'Np', 'N,Mp' or '/re/p'")
        return
    if cmd == "awk":
        i, prog = 0, None
        while i < len(args):
            if args[i] in ("-F", "-v"):
                i += 2
                continue
            if re.fullmatch(r"-F.+|-v.+", args[i]):
                i += 1
                continue
            need(not args[i].startswith("-"), f"awk option {args[i]}")
            prog = args[i]
            break
        need(prog is not None, "awk without a program")
        need(not re.search(r"getline|system|@load|@include|ENVIRON|close\(|fflush|\||>", prog or ""), "awk program with a pipe, redirect or comparison by > (use < or -v), or that runs, loads or reads the environment")
        return
    if cmd == "tar":
        need(args and re.fullmatch(r"-?[vzjJ]*t[vzjJ]*f?|--list", args[0]), "tar other than listing (tf / -tvf / --list)")
        rest = args[1:]
        need(all(x in ("-f", "-v", "-z", "-j", "-J") or not x.startswith("-") for x in rest), "tar listing with an option that runs or writes")
        return
    if cmd == "curl":
        i = 0
        boolean = set(f"-{c}" for c in "sSkLiIfvG46") | {"--silent", "--show-error", "--insecure", "--location", "--include", "--head", "--fail", "--get", "--compressed", "--http1.1", "--http2"}
        valued = {"-H", "--header", "-m", "--max-time", "--connect-timeout", "--cacert", "--resolve", "-w", "--write-out", "-o", "--output", "-u", "--user", "-A", "--user-agent", "--retry", "-e", "--referer"}
        while i < len(args):
            o = args[i]
            if o.startswith("-") and o != "-":
                key = o.split("=", 1)[0]
                if key in valued:
                    val = o.split("=", 1)[1] if "=" in o else (args[i + 1] if i + 1 < len(args) else "")
                    if key in ("-o", "--output"):
                        need(val == "/dev/null", "curl -o other than /dev/null")
                    if key in ("-H", "--header"):
                        need(not val.startswith("@") and not re.match(r"(?i)\s*x[-_][^:]*method", val), "curl -H from a file or with a method override")
                    if key in ("-w", "--write-out"):
                        need("%output{" not in val and not val.startswith("@"), "curl -w that writes a file")
                    i += 1 if "=" in o else 2
                    continue
                need(key in boolean or (re.fullmatch(r"-[A-Za-z0-9]{2,}", o) and all(f"-{ch}" in boolean for ch in o[1:])), f"curl option {o} is not on the GET-only list")
            else:
                need(re.match(r"https?://", o), "curl URL other than http:// or https://")
            i += 1
        return
    if cmd == "journalctl":
        only_opts(args, {"--no-pager", "-b", "-k", "-r", "--reverse", "-x", "-a", "-q", "--no-hostname", "--utc", "-e", "--merge", "-m", "--list-boots", "--disk-usage", "--system", "--user"},
                  {"-u", "--unit", "-n", "--lines", "-p", "--priority", "--since", "-S", "--until", "-U", "-o", "--output", "-g", "--grep", "-t", "--identifier", "--boot", "-D", "--directory", "--user-unit"}, max_positional=4)
        need(not re.search(r"--(vacuum|rotate|flush|sync|relinquish|setup-keys|update-catalog|cursor-file)", a), "journalctl maintenance or file-writing flag")
        return
    if cmd == "dmesg":
        only_opts(args, set(f"-{c}" for c in "THxkutL") | {"--ctime", "--human", "--decode", "--kernel", "--userspace", "--color"}, {"-l", "--level", "-f", "--facility", "--time-format"}, max_positional=0)
        return
    if cmd == "systemctl":
        verb, _ = parse(args, {"--no-pager", "-l", "--full", "--all", "-a", "--user", "--system", "--plain", "--no-legend", "--value", "-q", "--quiet", "-r", "--recursive"},
                        {"-t", "--type", "--state", "-p", "--property", "-n", "--lines", "-o", "--output"})
        need(verb in (None, "status", "is-active", "is-enabled", "is-failed", "cat", "show", "list-units", "list-timers", "list-unit-files", "list-sockets", "list-dependencies"), f"systemctl {verb}")
        need(not any(re.fullmatch(r"-[A-Za-z]*[HM].*|--[hm].*", x) for x in args), f"{cmd} -H/-M (it connects to another host)")
        return
    if cmd in ("timedatectl", "hostnamectl", "resolvectl", "loginctl"):
        verb, _ = parse(args, {"--no-pager", "-a", "--all", "--no-legend", "--value"}, {"-p", "--property"})
        need(verb in (None, "status", "show", "query", "list-sessions", "list-users", "show-session", "show-user", "statistics"), f"{cmd} {verb}")
        need(not any(re.fullmatch(r"-[A-Za-z]*[HM].*|--[hm].*", x) for x in args), f"{cmd} -H/-M (it connects to another host)")
        return
    if cmd in ("docker", "docker-compose", "podman"):
        return check_docker(cmd, args)
    if cmd == "pct":
        verb, rest = parse(args, set(), set())
        if verb == "exec":
            need(len(rest) >= 3 and re.fullmatch(r"[0-9]+", rest[0]) and rest[1] == "--", "pct exec other than <id> -- <command>")
            tail = rest[rest.index("--") + 1:]
            return check(" ".join(shlex.quote(x) for x in tail), depth + 1)
        need(verb in ("config", "list", "status", "pending", "df", "listsnapshot", "cpusets"), f"pct {verb}")
        return
    if cmd == "qm":
        verb, _ = parse(args, set(), set())
        need(verb in ("config", "list", "status", "pending", "showcmd", "listsnapshot"), f"qm {verb}")
        return
    if cmd == "pvesh":
        verb, _ = parse(args, set(), set())
        need(verb in ("get", "ls", "usage"), f"pvesh {verb}")
        return
    if cmd == "cscli":
        verb, rest = (args[0] if args else None), args[1:]
        nouns = {"alerts", "decisions", "bouncers", "machines", "collections", "parsers", "scenarios", "postoverflows", "hub", "lapi", "capi", "allowlists", "contexts", "notifications", "appsec-configs", "appsec-rules", "console"}
        if verb in ("metrics", "version"):
            return
        need(verb in nouns and rest and rest[0] in ("list", "inspect", "status"), "cscli other than <noun> list|inspect|status, metrics or version")
        return
    if cmd == "sqlite3":
        return check_sqlite(args)
    if cmd == "ip":
        rest = list(args)
        while rest and re.fullmatch(r"-(4|6|s|d|j|br|brief|c|color|o|oneline|p|pretty|details|stats|json)", rest[0]):
            rest = rest[1:]
        need(rest and rest[0] in ("a", "addr", "address", "l", "link", "r", "route", "n", "neigh", "neighbour", "rule", "ru"), "ip object other than addr/link/route/neigh/rule")
        need(len(rest) == 1 or rest[1] in ("show", "list", "ls"), "ip other than show/list")
        return
    if cmd in ("iptables", "ip6tables"):
        only_opts(args, {"-L", "-S", "-n", "-v", "-x", "--line-numbers", "--list", "--list-rules", "--numeric", "--verbose", "--exact", "-nL", "-vnL", "-nvL", "-Ln", "-Lnv"}, {"-t", "--table"}, max_positional=1)
        need(re.search(r"(^|\s)-\w*[LS]\b|--list", a), f"{cmd} without -L/-S")
        return
    if cmd == "nft":
        verb, rest = parse(args, {"-a", "-n", "-j", "--handle", "--numeric", "--json", "-s", "--stateless"}, set())
        need(verb == "list" and all(re.fullmatch(r"[A-Za-z0-9_.:][A-Za-z0-9_.:-]*", x) for x in rest), "nft other than list <plain names> (nft treats ; inside an argument as a new command)")
        return
    if cmd in ("zfs", "zpool"):
        verb, rest = parse(args, set(), set())
        need(verb in ("list", "get", "status", "iostat", "history"), f"{cmd} {verb}")
        need(not any(re.fullmatch(r"-\w*c\w*", x) for x in rest), f"{cmd} -c runs vdev scripts")
        return
    if cmd == "crontab":
        need(args == ["-l"] or (len(args) == 3 and args[0] == "-l" and args[1] == "-u") or (len(args) == 3 and args[0] == "-u" and args[2] == "-l"), "crontab other than -l")
        return
    if cmd == "wg":
        need(args[:1] == ["show"] and not re.search(r"\b(dump|private-key|preshared-keys)\b", a), "wg other than show (no dump or keys)")
        return
    if cmd in ("tailscale", "ufw"):
        verb, _ = parse(args, set(), set())
        need(verb in ("status", "ip", "version", "netcheck", "whois", "ping"), f"{cmd} {verb}")
        return
    if cmd == "apt":
        verb, rest = parse(args, set(), set())
        need(verb in ("list", "policy", "show", "search"), f"apt {verb}")
        only_opts(rest, {"--installed", "--upgradable", "-a", "--all-versions", "--names-only", "--full"}, set())
        return
    if cmd == "dpkg":
        need(args and re.fullmatch(r"-[lsLS]|--(list|status|listfiles|search|audit)", args[0]), "dpkg other than -l/-s/-L/-S")
        return
    if cmd == "dpkg-query":
        only_opts(args, {"-W", "--show", "-l", "--list", "-s", "--status", "-L", "--listfiles", "-S", "--search", "-p", "--print-avail"},
                  {"-f", "--showformat"})
        need(any(x in ("-W", "--show", "-l", "--list", "-s", "--status", "-L", "--listfiles", "-S", "--search", "-p", "--print-avail") for x in args), "dpkg-query without a query action")
        return
    if cmd == "pacman":
        need(args and re.fullmatch(r"-Q[a-z]*", args[0]), "pacman other than -Q")
        return
    if cmd == "smartctl":
        for i, x in enumerate(args):
            if x in ("-l", "--log") or x.startswith(("-l", "--log=")):
                v = (args[i + 1] if i + 1 < len(args) else "") if x in ("-l", "--log") else x.split("=", 1)[1] if x.startswith("--log=") else x[2:]
                need(re.fullmatch(r"(error|xerror|selftest|xselftest|devstat|scttemp|scterc|sataphy)", v), "smartctl -l other than a read log (no values, no reset)")
        only_opts(args, {"-a", "-i", "-H", "-A", "-x", "-j", "--all", "--info", "--health", "--json"}, {"-l", "-d", "--device"}, max_positional=1)
        return
    if cmd == "ping":
        only_opts(args, {"-q", "-n", "-4", "-6"}, {"-c", "-W", "-w"}, max_positional=1)
        need(any(x.startswith("-c") for x in args), "ping without -c")
        return
    raise Deny(f"'{cmd}' is not on the inspector's read-only list")


def check_sqlite(args):
    readonly, i = False, 0
    while i < len(args) and args[i].startswith("-"):
        o = args[i]
        if o == "-readonly":
            readonly = True
        elif o in ("-separator", "-nullvalue", "-newline"):
            i += 1
        elif o not in ("-json", "-csv", "-header", "-noheader", "-line", "-list", "-column", "-box", "-markdown", "-table", "-batch", "-bail", "-quote", "-tabs"):
            raise Deny(f"sqlite3 option {o}")
        i += 1
    need(i < len(args), "sqlite3 without a database")
    db, sql = args[i], args[i + 1:]
    need(sql, "sqlite3 needs its SQL as an argument (it would read dot-commands from stdin)")
    need(readonly or re.fullmatch(r"file:[^?&#]+\?mode=ro", db), "sqlite3 without read-only mode (exactly file:<db>?mode=ro, or -readonly before the database)")
    for st in [x.strip() for s in sql for x in s.split(";") if x.strip()]:
        if st.startswith("."):
            need(re.fullmatch(r"\.(tables|schema|indexes|indices|headers|mode|dbinfo|fullschema|show|width)\b[^;|]*", st), "sqlite3 dot-command other than .tables/.schema/.mode")
            continue
        need(not re.search(r"\b(attach|detach|vacuum|backup|load_extension|writefile|readfile|edit|fts3_tokenizer)\b", st, re.I), "sqlite3 statement that opens, writes or loads files")
        need(re.match(r"(?is)\s*(select|with|explain|pragma\s+(table_info|index_list|index_info|database_list|table_list|user_version|schema_version|page_count|page_size|integrity_check|quick_check)\b)", st), "sqlite3 statement other than SELECT/WITH/read PRAGMA")


def check_docker(cmd, args):
    if cmd == "podman":
        need(not any(re.fullmatch(r"-[A-Za-z]*r[A-Za-z]*|--(remote|url|connection|identity|r|u|c|i)[a-z-]*(=.*)?", x) for x in args), "podman remote-connection option")
    rest = list(args)
    valued = {"-c", "--context", "--config", "-l", "--log-level", "--tlscacert", "--tlscert", "--tlskey"}
    cvalued = {"-f", "-p", "--file", "--project-name", "--env-file", "--project-directory", "--profile"}
    if cmd == "docker":
        while rest and rest[0].startswith("-"):
            key = rest[0].split("=", 1)[0]
            need(key in valued or key in ("--tls", "--tlsverify", "-D", "--debug"), f"docker global option {rest[0]}")
            rest = rest[1 if "=" in rest[0] or key in ("--tls", "--tlsverify", "-D", "--debug") else 2:]
        if rest and rest[0] == "compose":
            rest, cmd = rest[1:], "docker-compose"
    if cmd == "docker-compose":
        while rest and rest[0].startswith("-"):
            key = rest[0].split("=", 1)[0]
            need(key in cvalued, f"docker compose option {rest[0]}")
            need("://" not in (rest[0].split("=", 1)[1] if "=" in rest[0] else (rest[1] if len(rest) > 1 else "")), "docker compose option with a URL (it fetches remote files)")
            rest = rest[1 if "=" in rest[0] else 2:]
        s = rest[0] if rest else None
        need(s in ("ps", "logs", "config", "ls", "images", "top", "version", "port"), f"docker compose {s}")
        if s == "config":
            only_opts(rest[1:], {"--services", "--volumes", "--images", "--profiles", "--networks", "-q", "--quiet", "--no-interpolate", "--no-normalize", "--no-path-resolution", "--environment"}, {"--format", "--hash"}, max_positional=8)
        return
    s = rest[0] if rest else None
    if s in ("container", "image", "network", "volume", "system") and len(rest) > 1:
        need(rest[1] in ("ls", "list", "inspect", "logs", "df", "info", "top", "port", "stats"), f"docker {s} {rest[1]}")
        return
    need(s in ("ps", "logs", "inspect", "images", "version", "info", "stats", "top", "port", "events", "history"), f"{cmd} {s}")
    need(not (s == "stats" and "--no-stream" not in rest), "docker stats without --no-stream")
    need(not (s == "events" and "--until" not in " ".join(rest)), "docker events without --until (it never ends)")


def check_ssh(args, depth):
    i, check_mode = 0, False
    while i < len(args) and args[i].startswith("-"):
        o = args[i]
        if o == "-O":
            need(i + 1 < len(args) and args[i + 1] == "check" and not check_mode, "ssh -O other than a single 'check' (it would close or change the shared master)")
            check_mode, i = True, i + 2
            continue
        if o == "-o":
            v = args[i + 1] if i + 1 < len(args) else ""
            need(v in SSH_OK_OPTS or re.fullmatch(r"ConnectTimeout=[0-9]+", v), "ssh -o option not on the read-only list")
            i += 2
            continue
        need(re.fullmatch(r"-[qTnx]+", o), f"ssh option {o} (no tunnels, masters, proxies or alternate configs)")
        i += 1
    need(i < len(args), "ssh with no host")
    remote = args[i + 1:]
    if check_mode:
        need(not remote, "ssh -O check takes only a host")
        return
    need(remote, "interactive ssh (give a remote command)")
    if REQUIRE_CHECK:
        need(depth == 0, "ssh inside another command (a check on a remote host proves nothing about a warm connection here)")
        prev, sep = CTX["prev"], CTX["sep"]
        need(sep == "&&" and prev == ["ssh", "-O", "check", args[i]],
             f"ssh to {args[i]} must directly follow `ssh -O check {args[i]} &&` (warm connections only; a new one can need a hardware-key touch)")
    return check(" ".join(remote), depth + 1)


def check(text, depth=0):
    need(depth <= 6, "nested too deep")
    text = re.sub(r"[\r\n]+", " ; ", text)  # bash runs each line as its own command
    subset(text)
    # An fd number belongs to the redirect only when it touches it (`2>&1`, `2>/dev/null`); `cat 2 >/dev/null f`
    # passes 2 as an argument. Drop touching fd numbers before lexing, so a spaced digit stays a word.
    text = re.sub(r"(?:(?<=^)|(?<=[\s;&|]))[0-9]+(?=[<>])", "", text)
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|<>()")
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        toks = list(lex)
    except ValueError as e:
        raise Deny(f"cannot parse command: {e}")
    need(not any(re.search(r"/dev/(tcp|udp)/", x) for x in toks), "/dev/tcp or /dev/udp network redirect")
    segs, seps, seg, i = [], [None], [], 0
    while i < len(toks):
        t = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) else ""
        if t in (";", "&&", "||", "|", ";;", "|&"):
            segs.append(seg)
            seps.append(t)
            seg = []
        elif t in ("(", ")"):
            raise Deny("subshells and case patterns are not in the supported shell subset")
        elif t == "&":
            raise Deny("backgrounding with & (no daemons)")
        elif t in ("<<", "<<<", "<>", "<<-"):
            raise Deny("here-document, here-string or read-write redirect")
        elif t in (">&", "<&"):
            need(re.fullmatch(r"[0-9]+|-", nxt), "redirect to a file through >&")
            i += 1
        elif t in (">", ">>", ">|", "&>", "&>>"):
            need(nxt == "/dev/null", "output redirect into a file")
            i += 1
        elif t == "<":
            i += 1
        else:
            need(not re.fullmatch(r"[<>&|;()]+", t), f"shell operator {t}")
            seg.append(t)
        i += 1
    segs.append(seg)
    need(not (REQUIRE_CHECK and "||" in seps and any(s and os.path.basename(s[0]) == "ssh" for s in segs)),
         "|| in a command that runs ssh (it can skip the ssh -O check)")
    for k, s in enumerate(segs):
        CTX["prev"], CTX["sep"] = (segs[k - 1] if k else None), seps[k]
        check_segment(s, depth)


def check_segment(s, depth):
    while s and (s[0] in KEYWORDS or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", s[0])):
        if "=" in s[0] and s[0] not in KEYWORDS:
            need(s[0].split("=", 1)[0] in OK_ENV, f"environment override {s[0].split('=')[0]}")
        s = s[1:]
    while s and s[0] == "time":
        s = s[1:]
    if s and s[0] == "timeout":
        s = s[1:]
        while s and s[0].startswith("-"):
            s = s[2:] if s[0] in ("-s", "-k", "--signal", "--kill-after") else s[1:]
        need(s and re.fullmatch(r"[0-9.]+[smhd]?", s[0]), "timeout without a duration")
        s = s[1:]
    while s and re.fullmatch(r"[0-9]+", s[0]):
        s = s[1:]
    if not s:
        return
    word = s[0]
    need(not word.startswith(("$", "~")), "a command taken from a variable or home path")
    d, cmd = os.path.split(word)
    need(d in SAFE_DIRS, f"command from an unexpected path: {word}")
    need(cmd not in ("sudo", "doas", "su", "pkexec", "env", "nohup", "setsid", "xargs", "eval", "exec", "source", ".", "command", "builtin", "case"),
         f"'{cmd}' runs or elevates another command")
    need(not (cmd in ("python", "python3", "perl", "ruby", "node", "php", "lua", "tclsh") or re.fullmatch(r"python[0-9.]+", cmd)), f"interpreter '{cmd}'")
    check_args(cmd, s[1:], depth)


if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv[:1] == ["--require-check"]:
        REQUIRE_CHECK, argv = True, argv[1:]
    try:
        check(argv[0] if argv else sys.stdin.read())
    except Deny as e:
        print(e)
        sys.exit(1)
