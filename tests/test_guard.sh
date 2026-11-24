#!/usr/bin/env bash
# Regression cases for agent-bash-guard.sh. Usage: bash tests/test_guard.sh [path/to/agent-bash-guard.sh]
# Each case pipes {tool_input:{command}} into the guard as a role; any JSON output = deny, empty = allow.
B=${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/agent-bash-guard.sh}
command -v jq >/dev/null || { echo "jq required"; exit 2; }
fails=0; n=0
t() { role=$1 want=$2; shift 2; n=$((n+1)); out=$(jq -n --arg c "$*" '{tool_input:{command:$c}}' | "$B" "$role"); got=allow; [ -n "$out" ] && got=deny; [ "$got" = "$want" ] || { echo "WRONG [$role] want=$want got=$got: $*"; fails=$((fails+1)); }; }
W="systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G --"

# interpreter paths, version checks, grep -c, shell payloads
for c in '.venv/bin/python -m pytest -q' '/usr/bin/python3 -m pytest -q' 'venv/bin/pytest -q'; do t worker deny "$c"; done
for c in 'pytest --version' 'make --version' 'tsc --version' 'gradle --version && go version' 'python3 -m pytest --version' 'cargo --version' 'node --version'; do t researcher allow "$c"; done
for c in 'cd /r && ctest -V' 'cd /r && mvn clean package -V' 'pytest -k version' 'pytest --version && pytest -q' 'make; make --version'; do t worker deny "$c"; done
for c in "grep -c 'pytest' tests/a.py" "grep -c 'ssh ' deploy.sh" "grep -c 'make' Makefile"; do t worker allow "$c"; t reviewer allow "$c"; done
for c in 'bash -c "pytest -q"' "sh -c 'make'" "zsh -c 'ssh h'" "bash -lc \"cd /r && make\""; do t worker deny "$c"; done
# more runners and installs
for c in 'cargo check' 'cargo clippy' 'cmake --build build' 'pnpm run test' 'yarn run test' 'npm run build' 'go vet ./...' 'pnpm install' 'yarn install' 'uv sync' 'poetry install' 'bundle install'; do t worker deny "$c"; done
for c in "$W bash -c 'cd /r && cargo clippy'" "$W bash -c 'cd /r && pnpm run test'" "$W bash -c 'cd /work/r && cp -f --parents main/a.c main/new/b.c /var/tmp/orchestrate-copy-20261123-1-t1/ && cd /var/tmp/orchestrate-copy-20261123-1-t1 && . ~/esp/esp-idf/export.sh >/dev/null 2>&1 && idf.py build'"; do t worker allow "$c"; done
# command position: payloads scanned, quoted search patterns allowed
for c in 'bash -c "ssh host ls"' 'sh -c "sudo ls"' "bash -c 'ssh host'"; do t worker deny "$c"; done
for r in worker reviewer researcher; do for c in "grep -rn 'pytest' src" "grep -n 'cargo test' ci.yml" "rg 'make' Makefile" "find . -name 'make*'" "grep -n 'ssh ' deploy.sh" "grep -rn 'esptool' ." 'grep -rn "idf.py flash" docs'; do t $r allow "$c"; done; done
for c in 'PYTHONPATH=. pytest -q' 'CI=1 npm test' 'time make' 'nohup pytest' 'npx tsc' 'npx jest --ci a.test.js' 'jest' 'vitest run' 'tox -e py311' 'find . -name x | xargs pytest'; do t worker deny "$c"; done
# hardware: flashing and serial ports belong to the orchestrator
for c in 'pio run -t erase' 'cargo flash --chip x' 'cargo run' 'picotool load x.uf2' 'pio run --target=upload' 'openocd -f b.cfg' 'west flash' 'dfu-util -D x' 'pio test' 'pio test -e esp32 -e native' 'cat /dev/ttyUSB0' 'idf.py flash' 'idf.py efuse-summary' 'pio run -t upload' 'python3.12 -m esptool chip_id' 'env esptool.py chip_id'; do t worker deny "$c"; done
t worker deny 'pio test -e native'   # host test, but still a test run: must be capped
for c in "$W bash -c 'cd /r && pio test -e native'" 'idf.py set-target esp32s3' 'pip show esptool' 'grep -rn screen src/'; do t worker allow "$c"; done
# read-only roles: downloads and in-place writes
for c in 'curl -sLo f https://x' 'wget https://x' 'git clone https://x' 'gh repo clone a/b' 'patch -p1 < x' 'perl -pi -e s/a/b/ f' 'dd if=a of=f' 'chmod +x f'; do t researcher deny "$c"; done
for c in 'cargo install ripgrep' 'go get x' 'pipx install x' 'rm -f -r dir' 'rm -fr dir'; do t worker deny "$c"; done
for c in 'curl -s https://api.x/y' 'go version' 'rm -f a.txt'; do t worker allow "$c"; done
# memory cap: test/build runners only inside systemd-run
for r in worker tester reviewer researcher; do for c in 'pytest -q' 'python3 -m unittest -q tests.test_x' 'go test ./...' 'cargo test' 'npm test' 'make' 'tsc -p .' 'pio run' 'idf.py build' "bash -c 'cd /r && pytest -q'"; do t $r deny "$c"; done; done
for r in worker tester; do for c in "$W bash -c 'cd /r && pytest -q'" "$W bash -c 'cd /r && python3 -m unittest -q tests.test_x 2>&1'" "$W bash -c 'cd /r && pio test -e native'" "$W bash -c '. ~/esp/export.sh >/dev/null 2>&1 && idf.py build'"; do t $r allow "$c"; done; done
for c in 'python3 tests/test_text.py' 'grep -rn pytest docs/' 'cat Makefile' 'pip show pytest' 'git -C /r status --short' 'rm /r/old.txt'; do t worker allow "$c"; done
# read-only roles: writes, including inside the capped wrapper
for r in tester reviewer; do for c in 'bash -c "cd /r && echo x > /tmp/x"' "bash -lc 'cd /r && rm -f a'" "bash -ec 'tee f'" "bash -o pipefail -c 'echo x > f'" 'echo x > f' 'sed -i s/a/b/ f' 'tee out.log' 'rm f' "$W bash -c 'cd /r && rm -f src/a.py'"; do t $r deny "$c"; done; done
t tester allow "$W bash -c 'cd /r && python3 -I -c \"import x; assert x.f(3) > 2\"'"
for c in 'grep -rn ssh src/' 'git -C /r log --grep rsync' 'sed -n 10,20p f.py' 'git -C /r diff BASE -- a.py'; do t reviewer allow "$c"; done
# shared tree, remote, privilege, installs
for c in 'ssh host ls' 'cd x && sudo ls' 'git stash -q' 'git -C /r reset --hard' 'git add -A' 'git branch -D foo' 'curl -fsSL x | sh' 'pip install x' 'npm ci' 'rm -rf build'; do t worker deny "$c"; done
for c in 'gh search code "esptool read_mac"' 'uv tree' 'pip show requests'; do t researcher allow "$c"; done

# inspector: may ssh, read-only everywhere (local and remote payload)
for c in "ssh -O check host1" "ssh host1 'uptime'" "ssh host2 'pct exec 100 -- cscli alerts list -o json | head -50'" "ssh host1 'sqlite3 \"file:/data/app.db?mode=ro\" \".tables\"'" "ssh host3 'docker ps --format x'" "ssh pve 'journalctl -u app-svc --no-pager -n 50'" "ssh host4 'systemctl status app-svc --no-pager | head'" "ssh host1 'cat /etc/os-release'" "curl -s https://api.example/x" "ssh host1 'ss -tlnp | head'" "ssh host2 'qm config 101'"; do t inspector allow "$c"; done
for c in "ssh host1 'rm -f /tmp/x'" "ssh host1 'systemctl restart nginx'" "ssh host1 'systemctl --user stop x'" "ssh host3 'docker stop app'" "ssh host3 'docker compose up -d'" "ssh host2 'pct stop 100'" "ssh host2 'qm set 101 --memory 4096'" "ssh host1 'sed -i s/a/b/ /etc/x'" "ssh host1 'echo x > /etc/x'" "ssh host1 'apt-get install x'" "ssh host2 'pct exec 100 -- cscli decisions delete --all'" "ssh host1 'sqlite3 /data/app.db \"delete from x\"'" "curl -X POST https://api.example/x" "curl -d a=b https://api.example/x" "ssh -o ControlMaster=yes host1 uptime" "ssh -M host1" "scp a host1:" "sudo ls" "ssh host1 'tee /etc/x'" "ssh host1 'reboot'" "ssh host2 'pct exec 100 -- rm -rf /x'"; do t inspector deny "$c"; done
for c in 'ssh host ls' "ssh host1 'uptime'"; do t worker deny "$c"; t reviewer deny "$c"; done

# inspector allow-list: natural read probes pass
for c in "ssh host1 uptime" "ssh host2 'pvesh get /cluster/resources --output-format json'" "ssh host3 'docker compose -f x.yml ps'" "ssh host3 'docker logs --tail 50 app 2>&1 | grep -i error'" "ssh host2 'pct exec 100 -- sh -c \"ls /var/log | head\"'" "ssh host1 'find /etc -name \"*.conf\" | head'" "ssh host1 'sed -n 1,20p /etc/x'" "ssh -o BatchMode=yes -o ConnectTimeout=5 host1 uptime" "ssh host1 'df -h; free -m'" "ssh host1 'ls /x 2>/dev/null || echo none'" "jq .x f.json" "ssh host2 'zpool status'" "curl -sk -H 'Authorization: Bearer x' https://h/api"; do t inspector allow "$c"; done
# inspector allow-list: writes and escapes are denied
for c in "ssh h 'docker compose -f x.yml up -d'" "ssh h 'docker-compose up -d'" "ssh h 'docker container stop x'" "ssh h 'docker -H h stop x'" "ssh h 'docker image prune'" "ssh h '/bin/systemctl restart x'" "ssh h '/usr/bin/docker stop app'" "ssh h 'service nginx restart'" "ssh h '/etc/init.d/x restart'" "ssh h 'systemctl isolate rescue'" "ssh h 'pvesh set /nodes/x'" "ssh h 'vzdump 100'" "ssh h 'qm agent 100 exec ls'" "ssh h 'pct enter 100'" "ssh h 'crontab f'" "ssh h 'zpool destroy p'" "ssh h 'ufw allow 22'" "ssh h 'ip link set eth0 down'" "ssh h 'tailscale down'" "ssh h 'sysctl -w a=b'" "ssh h 'journalctl --vacuum-time=1d'" "curl -sXDELETE https://x" "curl -s --request POST https://x" "curl -sd a=b https://x" "curl -Fa=b https://x" "curl --json {} https://x" "curl -K cfg" "ssh h 'sort -o /etc/x y'" "ssh h 'find / -delete'" "ssh h 'cat x | sh'" "ssh h 'sed -n w/etc/x f'" "ssh h 'wget URL'" "ssh h 'curl -O URL'" "ssh h 'unlink x'" "ssh h 'python3 -c \"import os\"'" "ssh h 'sqlite3 \"file:a?mode=ro\" \".output /etc/x\"'" "ssh -O exit h" "ssh -o ProxyCommand=x h" "ssh -L 1:a:2 h" "ssh -o 'ControlMaster auto' h uptime" "ssh h" "ssh h 'x=\$(rm -f a)'" "ssh h '\$CMD'" "ssh h 'uptime &'" "ssh h 'env rm x'" "ssh h 'xargs rm < f'"; do t inspector deny "$c"; done
# verifier: servers end with their timeout and bind to loopback
t verifier allow "$W bash -c 'cd /r && timeout -k 5 120 python3 -m http.server 8765 --bind 127.0.0.1'"
t verifier allow "$W bash -c 'cd /r && timeout -k 5 120 npx vite --host 127.0.0.1'"
for c in "$W bash -c 'cd /r && timeout 120 python3 -m http.server 8765'" "nohup python3 -m http.server 8765 --bind 127.0.0.1" "$W bash -c 'cd /r && npm start &'" "docker compose up -d" "docker run -d nginx" "setsid x"; do t verifier deny "$c"; done

# inspector: round-2 security findings (newlines, >&, argument escapes)
NL=$'\n'
for c in "ls${NL}systemctl restart nginx" "ssh h ls${NL}ssh h reboot" "cat a >&/tmp/f" "pvecm delnode x" "date -s 2020-01-01" "hostname newname" "nvidia-smi -r" "ss -K dst x" "uniq in /tmp/out" "yq -i .a=1 f" "sed 's/.*/id/ge' f" "sed -e'w /tmp/o' f" "awk 'BEGIN{\"touch /tmp/x\" | getline}'" "ssh -O check -O exit h" "dmesg -Tc" "ip l s eth0 down" "ip -batch -" "curl -D /tmp/h https://x" "tar tf a --checkpoint-action=exec=id" "rg --pre sh x" "docker compose config -o /tmp/x" "sqlite3 db 'delete from t -- -readonly'" "sqlite3 -readonly db '.open /tmp/x'" "wg show all dump" "LD_PRELOAD=x cat f" "/tmp/cat f" "diff <(ls) f"; do t inspector deny "$c"; done
for c in "date +%F" "hostname -f" "pvecm status" "sed -n '1,20p' /etc/x" "dmesg -T" "ip -br a" "ip route show" "sqlite3 -readonly /d.db 'select count(*) from t'" "wg show" "LC_ALL=C sort f" "ls /x 2>&1 | head"; do t inspector allow "$c"; done
# verifier: more detach routes and all-interface binds
for c in "systemd-run --user python3 -m http.server 8765 --bind 127.0.0.1" "tmux new -d x" "screen -dmS x y" "at now" "$W bash -c 'cd /r && timeout -k 5 120 npx vite --host 0.0.0.0'"; do t verifier deny "$c"; done

# inspector: shell subset (anything bash and the parser could read differently) and option allow-lists
for c in "echo \$'\\'' ; systemctl restart nginx #'" 'echo $(case x in x) systemctl restart nginx;; esac)' 'echo ${ systemctl restart nginx; }' "tar cf /tmp/x.tar test" "echo x | uniq - /tmp/out" "ss -D /tmp/f" "journalctl --cursor-file=/tmp/f" "curl -w '%output{/tmp/x}text' https://x" "systemctl -p status restart nginx" "timedatectl -p status set-time 2020-01-01" "nft -I list flush ruleset" "apt -t list install foo" "docker --tlscert ps restart foo" "cscli alerts flush list" "smartctl -l scterc,70,70 /dev/sda" "awk -p '{print}' f" "yq --in-place .a f" "rg --hostname-bin=x y" "iptables -L --zero" "GLIBC_TUNABLES=x cat f" "(ls)" "ls # c" "cat <<<x"; do t inspector deny "$c"; done
for c in "curl -s -o /dev/null -w '%{http_code}' https://x" "ssh host2 'pct list'" "ssh host1 'journalctl -u ssh --no-pager -n 50'" "systemctl --no-pager -p ActiveState show nginx" "cscli alerts list -o json" "cscli metrics" "docker --context x ps" "stat -c %Y f"; do t inspector allow "$c"; done
for c in "sleep 600 & echo started" "systemd-run --user --scope sleep 1 ; systemd-run --user sleep 1000"; do t verifier deny "$c"; done

# loops and $-expansion are out of the inspector's subset (a variable can hold an option); awk has no > at all
for c in "ssh host1 'for f in a b; do cat \$f; done'" "awk '\$1 > 5' f" "for f in a b; do cat \$f; done"; do t inspector deny "$c"; done
# awk program in double quotes would have $1 expanded by the remote shell: denied; the working form is allowed
t inspector deny "ssh host1 'awk \"{print \$1}\" /etc/hosts'"
t inspector deny "ssh host1 \"awk '{print \\\$1}' /etc/hosts\""
t inspector allow "ssh host1 cat /etc/hosts | awk '{print \$1}'"
t inspector allow 'echo $?'
# inspector: array-subscript evaluation, brace/variable/glob expansion, and pass-4 gaps
for c in "printf -v 'a[\$(id)]' x" "[ -v 'a[\$(id)]' ]" "echo hi | sort -n {-o,/dev/stdout}" "find /dev/null {-exec,echo,EXEC,{},';'}" "curl {-o,/tmp/f} https://x" "sort \$o" "sort \"\$o\"" "awk 'BEGIN{print \";\" > \"/dev/stderr\"}'" "echo 'flush ruleset' | nft list ruleset -f -" "sqlite3 'file:/d.db?mode=ro&mode=rw' 'select 1'" "sqlite3 -readonly /d.db 'select 1; delete from t'" "docker compose config -qo /dev/stdout" "curl gopher://127.0.0.1:6379/_FLUSHALL" "systemctl -H h status x" "docker -H ssh://h ps" "cat < /dev/tcp/h/80" "ls *.conf"; do t inspector deny "$c"; done
for c in "sqlite3 'file:/d.db?mode=ro' 'select 1; select 2'" "find /etc -name '*.conf'" "docker compose config --services" "awk '{print \$1}' f | sort | uniq -c"; do t inspector allow "$c"; done

# inspector: quoted operators, find allow-list (bfs -rm), sqlite stdin, apt/blkid options, curl -H @file
for c in "find /home/x '<' -delete" "sort '<' -o /tmp/f /etc/hosts" "find /x -name y -rm" "find /x -files0-from f" "echo '.shell touch /tmp/pwn' | sqlite3 -readonly /tmp/x.db" "apt list -o Dir::Cache::pkgcache=/p" "blkid -c /tmp/f" "curl -H @f https://x" "echo ';'"; do t inspector deny "$c"; done
for c in "find /var/log -mtime -1 -size +1M -print" "apt list --installed" "blkid -o value -s UUID /dev/sda1" "grep -E 'a|b' f"; do t inspector allow "$c"; done

# inspector: backslash inside double quotes (bash drops it before $ and backtick), nft ; inside args, pass-6 minors
for c in 'sh -c "echo \"\$(id)\""' 'ssh host1 "echo \"\$(id)\""' 'pct exec 101 -- sh -c "echo \"\`id\`\""' "nft list 'ruleset; flush ruleset'" "curl -H 'X-HTTP-Method: DELETE' https://x" "docker compose -f http://h/x.yml ps" "zpool status -c smart" "ping -c 1 -f h" "sort -o/tmp/x f"; do t inspector deny "$c"; done
for c in "sort -k5 f" 'ssh host1 "grep \"x y\" /etc/f"' "nft -a list table inet filter" "ping -c 2 -W 1 h" "pacman -Qi bash"; do t inspector allow "$c"; done
# inspector: pct exec words before --, attached smartctl -l, non-ASCII fd digits, quote-split /dev/tcp, -H/-M after the verb
for c in "pct exec 100 touch /tmp/x -- ls" "smartctl -lscterc,70,70 /dev/sda" "echo x >& ٣" "cat < /dev/t\"\"cp/127.0.0.1/1" "systemctl status x -H user@host" "loginctl show-session 1 -M m" "curl -H 'X_HTTP_Method_Override: DELETE' https://x"; do t inspector deny "$c"; done
for c in "smartctl -lerror /dev/sda" "systemctl status nginx --no-pager -n 20"; do t inspector allow "$c"; done
# inspector: -H/-M in option clusters and long-option abbreviations; podman remote connections
for c in "systemctl status -lH otherhost sshd" "systemctl status --hos=otherhost sshd" "loginctl list-sessions -aH otherhost" "podman ps --remote --url ssh://other" "podman ps -r"; do t inspector deny "$c"; done
for c in "systemctl status nginx --no-pager -l" "podman ps -a"; do t inspector allow "$c"; done
# review loop round 1: pacman queries for all roles, interpreter flags before -m, a systemd-run scope without slice+MemoryMax is no cap
for c in "pacman -Qi bash" "pacman -Q"; do t researcher allow "$c"; done
for c in "pacman -Q x; pacman -S y" "pacman -Syu"; do t researcher deny "$c"; done
for c in "python3 -I -m pytest" "python3 -u -m unittest" "systemd-run --user --scope pytest" "systemd-run --user --scope -p MemoryMax=6G pytest"; do t worker deny "$c"; done
t worker allow "systemd-run --user --scope --quiet --slice=orchestrate.slice -p MemoryMax=6G -p MemorySwapMax=1G -- bash -c 'cd /work/r && python3 -I -m pytest'"
# review loop round 2: systemd-run rule anchored to command position; verifier & inside a quoted URL is not a background job
t reviewer allow "grep -n 'systemd-run\\|pytest' notes.md"
t verifier allow "curl -s 'http://127.0.0.1:8000/x?a=1&b=2'"
for c in "sleep 600 & echo started" "bash -c 'sleep 600 &'"; do t verifier deny "$c"; done
t inspector allow "ssh -O check host1 && ssh -o BatchMode=yes host1 'uptime'"
# security: quote stripping removes single-quoted spans only, paired the way bash pairs them
for c in 'echo "$(pytest)"' 'echo "`make`"' "echo \"it's\"; pytest; echo \"x'\"" "echo \"'\" ; pytest ; echo \"'\"" "echo \\'; pytest; echo \\'"; do t worker deny "$c"; done
for c in 'echo "$(sleep 600 &)"' "echo \"'\" ; sleep 600 & echo \"'\"" "echo \\'; sleep 600 & echo \\'"; do t verifier deny "$c"; done
t worker allow "grep -rn 'make test' README.md"
# security: no quote stripping across comments, heredocs, $'..' or an unclosed quote
NL=$'\n'
for x in "pytest|worker" "sleep 600 &|verifier"; do r=${x#*|}; c=${x%%|*}
  t $r deny "# don't skip${NL}$c"; t $r deny "cat <<EOF${NL}it's${NL}EOF${NL}$c${NL}echo 'x'"; t $r deny "echo \$'\\''; $c; echo \$'\\''"; t $r deny "echo x # '${NL}$c${NL}# '"; t $r deny "echo 'unclosed; $c"
done
# security: strip only from simple read commands (nested quotes in substitutions, sh flags before -c, eval)
for x in "pytest|worker" "sleep 600 &|verifier"; do r=${x#*|}; c=${x%%|*}
  t $r deny "echo \"\$(echo \"'\")\"; $c; echo \\'"; t $r deny "echo \"\${x:-\"'\"}\"; $c; echo \\'"; t $r deny "bash -e -c '$c'"; t $r deny "sh -x -c '$c'"; t $r deny "(echo 'a'; $c)"
done
t verifier deny "eval 'sleep 600 &'"
t reviewer allow "grep -c '^pytest\$' f | head"
# security: process substitution and function bodies stop quote stripping
for c in "cat <(eval 'a; pytest')" "grep x <(eval 'a; pytest')" "cat <(bash -e -c 'a; make')" "echo a >(eval 'a; make')" "cat () ( eval 'a; make' ) && cat" "cat () { eval 'a; make'; } && cat"; do t worker deny "$c"; done
for c in "cat <(eval 'python3 -m http.server --bind 127.0.0.1 &')" "cat <(bash -e -c 'sleep 600 &')"; do t verifier deny "$c"; done
echo "cases=$n fails=$fails"
[ "$fails" -eq 0 ]
