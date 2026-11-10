#!/bin/sh
# Command dispatch: "sshd" (or nothing) starts the SSH server, anything
# else is executed as given (for example "selftest").
#
# Keys live only inside the container, in the volume at /etc/ssh/keys: the
# host key and the client key pair. The client private key is printed on the
# console at every start; the PC uses it for a run and keeps no copy.
set -eu

cmd="${1:-sshd}"

if [ "$cmd" != "sshd" ]; then
    exec "$@"
fi

keys=/etc/ssh/keys
mkdir -p /run/sshd "$keys"
chmod 700 "$keys"
if [ ! -f "$keys/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C rk86-vvp-host -f "$keys/ssh_host_ed25519_key"
fi
if [ ! -f "$keys/client_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C rk86-vvp -f "$keys/client_ed25519"
fi

home="$(getent passwd sim | cut -d: -f6)"
mkdir -p "$home/.ssh"
cp "$keys/client_ed25519.pub" "$home/.ssh/authorized_keys"
chown -R sim:sim "$home/.ssh"
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/authorized_keys"

echo "==== rk86-vvp client key: copy the lines from BEGIN to END ===="
cat "$keys/client_ed25519"
echo "==== rk86-vvp client key end ===="

exec /usr/sbin/sshd -D -e
