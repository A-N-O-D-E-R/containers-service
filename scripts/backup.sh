#!/bin/bash
# Offsite backup: consistent DB dumps, then rclone sync to an encrypted
# (rclone crypt) remote. Adapted from mbaelde/sober-selfhost.
#
#   anode-backup <env>        # env = local | prod, reads .env-<env>
#
# Needs: rclone with RCLONE_REMOTE configured as a `crypt` remote
# (see README "Backups"). Gated DB containers stopped by Sablier are
# started for the dump; Sablier puts them back to sleep after one session.
set -uo pipefail

dir=$(dirname "$(dirname "$(realpath "$0")")")
env="${1:?Usage: $0 <env>}"
env_file="$dir/.env-${env}"
[[ -f "$env_file" ]] && { set -a; source "$env_file"; set +a; }

REMOTE="${RCLONE_REMOTE:?set RCLONE_REMOTE in $env_file}"
DUMP_DIR="${BACKUP_DIR:?set BACKUP_DIR}/dumps"
mkdir -p "$DUMP_DIR"
ERRORS=0

log() { echo "[backup] $*"; }
fail() { log "ERROR: $*"; ERRORS=$((ERRORS + 1)); }

notify() {
  [[ -n "${WEBHOOK_URL:-}" ]] || return 0
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"content\":\"$1\"}" "$WEBHOOK_URL" >/dev/null || true
}

# container id for a compose service name (running or stopped)
cid() { docker ps -aq --filter "label=com.docker.compose.service=$1" | head -1; }

dump_pg() { # <compose-service> <db-user>
  local c; c=$(cid "$1")
  [[ -n "$c" ]] || { log "skip $1: no container"; return 0; }
  docker start "$c" >/dev/null || { fail "start $1"; return; }
  for _ in $(seq 30); do docker exec "$c" pg_isready -q -U "$2" && break; sleep 2; done
  docker exec "$c" pg_dumpall -c -U "$2" | gzip > "$DUMP_DIR/$1.sql.gz" \
    && log "dumped $1" || fail "dump $1"
}

START=$(date +%s)
notify "Backup started ($env -> $REMOTE)"

dump_pg shared-db admin
dump_pg immich-postgres "${IMMICH_DB_USER:-postgres}"
dump_pg penpot-postgres "${PENPOT_DB_USER:-penpot}"
dump_pg posthog-db posthog

if c=$(cid shared-nosql) && [[ -n "$c" ]]; then
  docker exec "$c" mongodump --quiet --archive --gzip -u admin -p "$ADMIN_NOSQL_PASSWORD" \
    --authenticationDatabase admin > "$DUMP_DIR/shared-nosql.archive.gz" \
    && log "dumped shared-nosql" || fail "dump shared-nosql"
fi

# redis writes dump.rdb into ${BACKUP_DIR}/cache, synced below
if c=$(cid shared-cache) && [[ -n "$c" ]]; then
  docker exec "$c" redis-cli SAVE >/dev/null || fail "redis SAVE"
fi

sync_remote() { # <src> <dst> [rclone args...]
  local src="$1" dst="$2"; shift 2
  [[ -d "$src" ]] || { log "skip $src: missing"; return 0; }
  rclone sync "$src" "$REMOTE:$dst" --log-level NOTICE "$@" && log "synced $src" || fail "sync $src"
}

# Live database files are excluded: their dumps (or garage's own
# metadata snapshots in s3/meta/snapshots) are the consistent copy.
sync_remote "$BACKUP_DIR" infra \
  --exclude "db/**" --exclude "nosql/**" --exclude "s3/meta/db.lmdb/**"
sync_remote "${S3_DATA_DIR:-}" data --exclude "immich/pgdata/**" --exclude "immich/model-cache/**"
sync_remote "${CERTS_DIR:-}" certs
sync_remote "${MKCERT_CAROOT:-}" mkcert-ca
rclone copy "$env_file" "$REMOTE:env" --log-level NOTICE || fail "copy env file"

DUR=$(( $(date +%s) - START ))
if (( ERRORS == 0 )); then
  notify "Backup finished in ${DUR}s"
else
  notify "Backup finished with $ERRORS error(s) in ${DUR}s"
fi
log "done in ${DUR}s, errors: $ERRORS"
exit $(( ERRORS > 0 ))
