#!/bin/bash
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
# Spike helper: join a Wi-Fi network from the GodseonDongle guest through its control API.
# The password is typed here and goes to the VM in the request body (never on a command line).
#   spike/connect.sh <vm-ip> <token>
# Static IPv4 (optional), in the API's hex form, e.g. 192.168.50.20/24 via 192.168.50.1 with
# an extra route 10.10.0.0/24 via 192.168.50.254:
#   STATIC="ip=C0A83214&prefix=24&gw=C0A83201&rt=0A0A000018C0A832FE" spike/connect.sh <vm-ip> <token>
set -eu
vm=${1:?vm ip}
token=${2:?token}
hex() { printf '%s' "$1" | xxd -p | tr -d '\n' | tr 'a-f' 'A-F'; }

read -r -p "SSID: " ssid
read -r -s -p "Password for $ssid: " password
echo
# The guest takes the 256-bit WPA PSK (PBKDF2-HMAC-SHA1(passphrase, ssid, 4096)), so the
# passphrase itself never reaches the VM. It is handed to python on stdin, not argv.
psk=$(printf '%s' "$password" | SSID="$ssid" python3 -c 'import hashlib, os, sys
print(hashlib.pbkdf2_hmac("sha1", sys.stdin.buffer.read(), os.environ["SSID"].encode(), 4096, 32).hex())')
unset password
body="ssid=$(hex "$ssid")&psk=$psk&sae=&hidden=0"
if [ -n "${STATIC:-}" ]; then
    body="$body&$STATIC"
fi
printf '%s' "$body" | curl -sS -m 20 -X POST --data-binary @- "http://$vm:9408/cgi-bin/api?action=connect&token=$token"
echo
echo "waiting for the association..."
for _ in $(seq 1 20); do
    status=$(curl -sS -m 5 "http://$vm:9408/cgi-bin/api?action=status&token=$token" || true)
    case "$status" in
        *'"ipv4":""'*) ;;
        *'"wpa_state":"COMPLETED"'*) break ;;
    esac
    sleep 2
done
echo "$status"
