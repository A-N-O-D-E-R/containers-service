#!/bin/bash
# Wake the (suspended) server from anywhere. From mbaelde/sober-selfhost.
#
# A magic packet only works as a broadcast on the server's LAN, and a
# sleeping server cannot answer on Tailscale. So run this ON an always-on
# device of the same LAN (Pi, NAS, router), reached over Tailscale:
#
#   you --tailscale ssh--> relay (LAN) --broadcast--> server
#   ssh relay ./wol-relay.sh aa:bb:cc:dd:ee:ff 192.168.1.255
#
# Needs `wakeonlan` on the relay. Server-side setup: see README "Wake-on-LAN".
set -euo pipefail

MAC="${1:?Usage: $0 <server-MAC> [broadcast-addr]}"
BROADCAST="${2:-192.168.1.255}"

wakeonlan -i "$BROADCAST" "$MAC"
echo "Magic packet sent to $MAC via $BROADCAST"
