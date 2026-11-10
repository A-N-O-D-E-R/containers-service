#!/bin/bash
# Suspend the host once it has been idle for SUSPEND_IDLE_MINUTES.
# Run every few minutes by anode-suspend.timer. Wake it with scripts/wol-relay.sh.
#
#   anode-suspend <env> [--dry-run]
#
# Idle means all of:
#   - no Sablier-gated container is running (all sessions expired)
#   - no client connection to Traefik on :80/:443
#   - no logged-in user session (ssh, console)
#   - the backup job is not running
#   - none of SUSPEND_BLOCKERS (container names) is running
set -euo pipefail

dir=$(dirname "$(dirname "$(realpath "$0")")")
env="${1:?Usage: $0 <env> [--dry-run]}"
dry_run="${2:-}"
env_file="$dir/.env-${env}"
[[ -f "$env_file" ]] && { set -a; source "$env_file"; set +a; }

idle_minutes="${SUSPEND_IDLE_MINUTES:-20}"
stamp=/run/anode-idle-since

busy_reason() {
  [[ -n "$(docker ps -q --filter label=sablier.enable=true)" ]] && { echo "gated containers running"; return; }

  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' traefik 2>/dev/null || echo 0)
  if (( pid > 0 )) && [[ -n "$(nsenter -t "$pid" -n ss -Htn state established '( sport = :80 or sport = :443 )')" ]]; then
    echo "traefik has client connections"; return
  fi

  [[ -n "$(who)" ]] && { echo "user logged in"; return; }
  systemctl is-active --quiet anode-backup.service && { echo "backup running"; return; }

  local c
  for c in ${SUSPEND_BLOCKERS:-}; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] && { echo "$c running"; return; }
  done
  return 0
}

reason=$(busy_reason)
if [[ -n "$reason" ]]; then
  rm -f "$stamp"
  echo "busy: $reason"
  exit 0
fi

[[ -f "$stamp" ]] || { touch "$stamp"; echo "idle: starting ${idle_minutes}m countdown"; exit 0; }

idle_for=$(( ($(date +%s) - $(stat -c %Y "$stamp")) / 60 ))
if (( idle_for < idle_minutes )); then
  echo "idle for ${idle_for}m / ${idle_minutes}m"
  exit 0
fi

echo "idle for ${idle_for}m: suspending"
rm -f "$stamp"
[[ "$dry_run" == "--dry-run" ]] || systemctl suspend
