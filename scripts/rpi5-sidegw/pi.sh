#!/bin/bash
# Run a command (or a script on stdin with -s) on the Pi 5 side gateway as root, using the dedicated key.
# Usage: pi.sh 'remote command'      |      pi.sh -s < script.sh
export MSYS_NO_PATHCONV=1
SSH=/c/Windows/System32/OpenSSH/ssh.exe
OPTS=(-i 'D:\Banana_Pi_r3mini\docs\私密\rpi5-sidegw\id_ed25519_rpi5' -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
      -o ServerAliveInterval=15 -o 'UserKnownHostsFile=D:\Banana_Pi_r3mini\docs\私密\rpi5-sidegw\known_hosts' -o StrictHostKeyChecking=yes)
if [ "${1:-}" = "-s" ]; then
	exec "$SSH" "${OPTS[@]}" root@192.168.0.245 'sh -s'
fi
exec "$SSH" "${OPTS[@]}" root@192.168.0.245 "$1"
