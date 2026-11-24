#!/usr/bin/env bash
# Create (or remove) a read-only `inspector` account on one of your hosts.
#   deploy/inspector-account.sh install <ssh host> <public key file>
#   deploy/inspector-account.sh remove  <ssh host>
# <ssh host> is a login that is root or may sudo. Run it yourself: it changes the host.
# The account has no password, no sudo, and one key that can only run deploy/inspector-shell, which lets a
# command through only if hooks/inspector_guard.py allows it. Everything the account owns is root-owned, so
# nothing it runs can change its own key or the guard. It joins `adm` and `systemd-journal` when they exist
# (logs and the journal); what needs root (pct, qm, docker, sshd -T) stays out of reach on purpose.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
lib=/usr/local/lib/orchestrate home=/var/lib/inspector
act=${1-} host=${2-} key=${3-}
case $host in ""|-*) echo "usage: $0 install <ssh host> <public key file> | remove <ssh host>" >&2; exit 1;; esac
# Runs on the host as root, from the unpacked bundle directory.
remote_as_root='t=$(mktemp -d) && tar -C "$t" -xf - && { s=; [ "$(id -u)" = 0 ] || s=sudo; $s sh "$t/remote.sh" "$t"; rc=$?; rm -rf "$t"; exit $rc; }'
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
case $act in
install)
  [ -f "$key" ] || { echo "no such public key file: $key" >&2; exit 1; }
  # Exactly one public key line: type, base64 blob, optional plain comment. Nothing that could add options.
  [ "$(wc -l < "$key")" -le 1 ] && grep -Eqx '(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=*( [A-Za-z0-9@._-]+)?' "$key" \
    || { echo "$key is not a single public key line" >&2; exit 1; }
  printf 'restrict,command="%s/inspector-shell" %s\n' "$lib" "$(cat "$key")" > "$w/authorized_keys"
  cp "$here/inspector-shell" "$here/../hooks/inspector_guard.py" "$w/"
  cat > "$w/remote.sh" <<EOF
set -eu
g=\$(getent group adm systemd-journal | cut -d: -f1 | paste -sd, -)
id inspector >/dev/null 2>&1 || useradd --system --home-dir $home --shell /bin/bash inspector
usermod -p '*' -G "\$g" inspector   # '*': no password can match, and sshd does not treat it as a locked account
install -d -o root -g root -m 755 $lib $home $home/.ssh
install -o root -g root -m 755 "\$1/inspector-shell" $lib/
install -o root -g root -m 644 "\$1/inspector_guard.py" $lib/
install -o root -g root -m 644 "\$1/authorized_keys" $home/.ssh/authorized_keys
echo "inspector account installed (groups: \${g:-none})"
EOF
  ;;
remove)
  cat > "$w/remote.sh" <<EOF
set -eu
! id inspector >/dev/null 2>&1 || userdel inspector
rm -rf $home $lib
echo "inspector account removed"
EOF
  ;;
*) echo "usage: $0 install <ssh host> <public key file> | remove <ssh host>" >&2; exit 1;;
esac
tar -C "$w" -cf - . | ssh "$host" "$remote_as_root"
