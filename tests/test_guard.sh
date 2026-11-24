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

echo "cases=$n fails=$fails"
[ "$fails" -eq 0 ]
