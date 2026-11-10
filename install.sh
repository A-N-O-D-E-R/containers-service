#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/A-N-O-D-E-R/containers-service.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/anode}"
BRANCH="${BRANCH:-master}"
SCRIPT_NAME="${BASH_SOURCE[0]:-$0}"
SYSTEMD_DIR="/etc/systemd/system"
EXCLUDED=(traefik sablier db cache)

#==============================================================================#
#                               Utility functions
#==============================================================================#
log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

generate_password() {
  openssl rand -base64 24 | tr -d '\n'
}

generate_hex() {
  openssl rand -hex 32
}

#==============================================================================#
#                             Installation functions
#==============================================================================#

check_os() {
  [[ "$(uname -s)" == "Linux" ]] || die "Linux required"

  command -v systemctl >/dev/null \
    || die "systemd required"

  [[ "$EUID" -eq 0 ]] \
    || die "must run as root"
}

install_packages() {
  local packages=("$@")

  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y "${packages[@]}"

  elif command -v dnf >/dev/null; then
    dnf install -y "${packages[@]}"

  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm "${packages[@]}"

  else
    die "unsupported package manager"
  fi
}

check_deps() {
  local missing=()

  command -v git >/dev/null || missing+=(git)
  command -v docker >/dev/null || missing+=(docker)
  command -v keepassxc-cli >/dev/null || missing+=(keepassxc-cli)

  if ! command -v docker-compose >/dev/null \
     && ! docker compose version >/dev/null 2>&1; then
    missing+=(docker-compose)
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "installing dependencies: ${missing[*]}"

    case "${missing[*]}" in
      *docker*)
        install_packages git docker.io docker-compose-plugin || \
        install_packages git docker docker-compose-plugin
        ;;
      *)
        install_packages "${missing[@]}"
        ;;
    esac

    systemctl enable --now docker
  fi

  command -v mkcert >/dev/null \
    || warn "mkcert not installed (needed for TLS certificates)"

  command -v rclone >/dev/null \
    || warn "rclone not installed (needed for anode-backup)"

  command -v tailscale >/dev/null \
    || warn "tailscale not installed (needed for remote access)"

  command -v s3fs >/dev/null \
    || warn "s3fs not installed (needed for object storage mounts)"
}

sync_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "updating repository"

    git -C "$INSTALL_DIR" fetch origin
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only

  else
    log "cloning repository"

    git clone \
      --branch "$BRANCH" \
      "$REPO_URL" \
      "$INSTALL_DIR"
  fi
}

is_excluded() {
  local app="$1"

  for e in "${EXCLUDED[@]}"; do
    [[ "$app" == "$e" ]] && return 0
  done

  return 1
}

needs_db() {
  local app="$1"

  grep -ql "shared-db" \
    "$INSTALL_DIR/$app"/compose-*.yml \
    2>/dev/null
}

needs_cache() {
  local app="$1"

  grep -ql "shared-cache" \
    "$INSTALL_DIR/$app"/compose-*.yml \
    2>/dev/null
}

link_units() {
  shopt -s nullglob

  for unit in "$INSTALL_DIR"/*.service "$INSTALL_DIR"/*.target "$INSTALL_DIR"/*.timer; do
    ln -sf "$unit" "$SYSTEMD_DIR/$(basename "$unit")"
  done

  for app in "${SELECTED_SERVICES[@]}"; do
    systemctl enable "anode-container@${app}.service"
  done
}

generate_overrides() {
  for app in "${AVAILABLE_SERVICES[@]}"; do
    service_selected "$app" || continue

    is_excluded "$app" && continue

    local dropin="$SYSTEMD_DIR/anode-container@${app}.service.d/order.conf"

    mkdir -p "$(dirname "$dropin")"

    local after="anode-container@traefik.service anode-container@sablier.service"
    local requires=""

    if needs_db "$app"; then
      after+=" anode-container@db.service"
      requires+=" anode-container@db.service"
    fi

    if needs_cache "$app"; then
      after+=" anode-container@cache.service"
      requires+=" anode-container@cache.service"
    fi

    cat > "$dropin" <<EOF
[Unit]
After=${after}
$( [[ -n "$requires" ]] && echo "Requires=${requires}" )
EOF

    log "generated override for ${app}"
  done
}

# symlinks: the scripts resolve the repo (compose files, .env-*) through realpath
install_scripts() {
  ln -sf "$INSTALL_DIR/manage-container.sh" /usr/local/bin/anode-container
  ln -sf "$INSTALL_DIR/scripts/backup.sh" /usr/local/bin/anode-backup
  ln -sf "$INSTALL_DIR/scripts/auto-suspend.sh" /usr/local/bin/anode-suspend
}

prompt_keepass_password() {
  if [[ -z "${KPXC_PASSWORD:-}" ]]; then
    read -rsp "KeePassXC master password: " KPXC_PASSWORD
    echo
  fi
}

create_keepass_db() {
  local db_file="$INSTALL_DIR/anode-service.db"

  if [[ -f "$db_file" ]]; then
    warn "KeePassXC database already exists"
    return
  fi

  log "creating KeePassXC database"

  prompt_keepass_password

  export KPXC_PASSWORD

  printf '%s\n%s\n' "$KPXC_PASSWORD" "$KPXC_PASSWORD" \
    | keepassxc-cli db-create --set-password "$db_file"
}

kpxc_group_exists() {
  prompt_keepass_password
  printf '%s\n' "$KPXC_PASSWORD" | \
    keepassxc-cli ls \
      "$INSTALL_DIR/anode-service.db" \
      "$1" \
    >/dev/null 2>&1
}

kpxc_create_group() {
  local group="$1"

  if ! kpxc_group_exists "$group"; then
    prompt_keepass_password
    printf '%s\n' "$KPXC_PASSWORD" | \
      keepassxc-cli mkdir \
        "$INSTALL_DIR/anode-service.db" \
        "$group"
  fi
}

kpxc_add() {
  local group="$1"
  local title="$2"
  local username="$3"
  local password="$4"

  kpxc_create_group "$group"

  local entry="${group}/${title}"
  prompt_keepass_password
  if printf '%s\n' "$KPXC_PASSWORD" | \
      keepassxc-cli show \
        "$INSTALL_DIR/anode-service.db" \
        "$entry" \
        >/dev/null 2>&1; then
    warn "KeePass entry already exists: $entry"
    echo $(printf '%s\n' "$KPXC_PASSWORD" | keepassxc-cli show -a Password "$INSTALL_DIR/anode-service.db" "$entry")
    return
  fi

  printf '%s\n%s\n%s\n' \
    "$KPXC_PASSWORD" \
    "$password" \
    "$password" \
  | keepassxc-cli add \
      --username "$username" \
      --password-prompt \
      "$INSTALL_DIR/anode-service.db" \
      "$entry"
  echo $password 
}


AVAILABLE_SERVICES=()
SELECTED_SERVICES=()

discover_services() {
  declare -A seen

  for f in "$INSTALL_DIR"/*/compose-*.yml; do
    local app
    app=$(basename "$(dirname "$f")")

    [[ -n "${seen[$app]+x}" ]] && continue

    seen[$app]=1
    AVAILABLE_SERVICES+=("$app")
  done
}

choose_services() {
  if [[ -n "${SERVICES:-}" ]]; then
    IFS=',' read -ra SELECTED_SERVICES <<< "$SERVICES"
    return
  fi

  echo
  log "available services:"

  local i=1
  for svc in "${AVAILABLE_SERVICES[@]}"; do
    printf "  [%d] %s\n" "$i" "$svc"
    ((i++))
  done

  echo
  read -rp "select services (all or comma-separated names): " reply

  if [[ "$reply" == "all" ]]; then
    SELECTED_SERVICES=("${AVAILABLE_SERVICES[@]}")
    return
  fi

  IFS=',' read -ra SELECTED_SERVICES <<< "$reply"
}

service_selected() {
  local target="$1"

  for svc in "${SELECTED_SERVICES[@]}"; do
    svc="$(echo "$svc" | xargs)"

    [[ "$svc" == "$target" ]] && return 0
  done

  return 1
}

configure_storage() {
  echo

  read -rp "Certificates directory [./certs]: " CERTS_DIR
  CERTS_DIR="${CERTS_DIR:-./certs}"

  read -rp "Logs directory [./.logs]: " LOG_DIR
  LOG_DIR="${LOG_DIR:-./.logs}"

  read -rp "Backup directory [/usr/local/share/anode/.backup]: " BACKUP_DIR
  BACKUP_DIR="${BACKUP_DIR:-/usr/local/share/anode/.backup}"

  read -rp "S3 mount directory [/mnt/backup-s3]: " S3_MOUNT_DIR
  S3_MOUNT_DIR="${S3_MOUNT_DIR:-/mnt/backup-s3}"

  read -rp "S3 credentials file [/root/.aws/credentials]: " TMP_S3_CREDENTIALS_FILE
  TMP_S3_CREDENTIALS_FILE="${TMP_S3_CREDENTIALS_FILE:-/root/.aws/credentials}"

  echo
  read -rp "How many Garage buckets? [3]: " bucket_count
  bucket_count="${bucket_count:-3}"

  GARAGE_BUCKETS=()

  for ((i=1; i<=bucket_count; i++)); do
    read -rp "Bucket #${i} name [bucket${i}]: " bucket_name
    bucket_name="${bucket_name:-bucket${i}}"

    GARAGE_BUCKETS+=("$bucket_name")
  done

  GARAGE_BUCKETS_CSV=$(IFS=, ; echo "${GARAGE_BUCKETS[*]}")

  echo
  echo "Available backup buckets:"
  for bucket in "${GARAGE_BUCKETS[@]}"; do
    echo " - $bucket"
  done

  echo
  read -rp "Backup bucket [${GARAGE_BUCKETS[0]}]: " BACKUP_BUCKET
  BACKUP_BUCKET="${BACKUP_BUCKET:-${GARAGE_BUCKETS[0]}}"

  S3_DATA_DIR="${BACKUP_DIR}/s3/data"

  mkdir -p \
    "$CERTS_DIR" \
    "$LOG_DIR" \
    "$BACKUP_DIR" \
    "$S3_DATA_DIR"
}

generate_env() {
  local env_file="$INSTALL_DIR/.env-local"

  [[ -f "$env_file" ]] && {
    warn ".env-local already exists"
    return
  }

  log "generating secrets"

  JWT_SECRET=$(generate_password)

  ADMIN_DB_PASSWORD=$(generate_password)
  ADMIN_NOSQL_PASSWORD=$(generate_password)

  ZABBIX_DB_PASSWORD=$(generate_password)
  FORGEJO_DB_PASSWORD=$(generate_password)
  RSS_DB_PASSWORD=$(generate_password)
  UNIFI_DB_PASSWORD=$(generate_password)

  ENCRYPTION_KEY=$(generate_hex)

  NOTE_PIN=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')

  GARAGE_INPUT=$(generate_password)
  GARAGE_RPC_SECRET=$(
    echo -n "$GARAGE_INPUT" \
      | sha256sum \
      | awk '{print $1}'
  )

  log "saving credentials to KeePassXC"

  ADMIN_DB_PASSWORD=$(kpxc_add "Databases" "admin-db" "admin" "$ADMIN_DB_PASSWORD" | tr -d '\n')
  ADMIN_NOSQL_PASSWORD=$(kpxc_add "Databases" "admin-nosql" "admin" "$ADMIN_NOSQL_PASSWORD" | tr -d '\n')

  ZABBIX_DB_PASSWORD=$(kpxc_add "Databases" "zabbix" "zabbix" "$ZABBIX_DB_PASSWORD" | tr -d '\n')
  FORGEJO_DB_PASSWORD=$(kpxc_add "Databases" "forgejo" "forgejo" "$FORGEJO_DB_PASSWORD" | tr -d '\n')
  RSS_DB_PASSWORD=$(kpxc_add "Databases" "rss" "rss" "$RSS_DB_PASSWORD" | tr -d '\n')
  UNIFI_DB_PASSWORD=$(kpxc_add "Databases" "unifi" "unifi" "$UNIFI_DB_PASSWORD" | tr -d '\n')

  JWT_SECRET=$(kpxc_add "Secrets" "jwt" "jwt" "$JWT_SECRET" | tr -d '\n')
  GARAGE_RPC_SECRET=$(kpxc_add "Secrets" "garage-rpc" "garage" "$GARAGE_INPUT" | tr -d '\n')
  NOTE_PIN=$(kpxc_add "web" "note.anode.com" "note" "$NOTE_PIN" | tr -d '\n')

  TZ=$(timedatectl show | grep Timezone | cut -d= -f2-)

  cat > "$env_file" <<EOF
EMAIL=you@anode.com
JWT_SECRET=${JWT_SECRET}

ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}
ADMIN_NOSQL_PASSWORD=${ADMIN_NOSQL_PASSWORD}

ZABBIX_DB_NAME=zabbix
ZABBIX_DB_USER=zabbix
ZABBIX_DB_PASSWORD=${ZABBIX_DB_PASSWORD}

FORGEJO_DB_NAME=forgejo
FORGEJO_DB_USER=forgejo
FORGEJO_DB_PASSWORD=${FORGEJO_DB_PASSWORD}

RSS_DB_NAME=rss
RSS_DB_USER=rss
RSS_DB_PASSWORD=${RSS_DB_PASSWORD}

CREDENTIALS="\${ZABBIX_DB_NAME}:\${ZABBIX_DB_USER}:\${ZABBIX_DB_PASSWORD},\${FORGEJO_DB_NAME}:\${FORGEJO_DB_USER}:\${FORGEJO_DB_PASSWORD},\${RSS_DB_NAME}:\${RSS_DB_USER}:\${RSS_DB_PASSWORD}"

UNIFI_DB_NAME=unifi
UNIFI_DB_USER=unifi
UNIFI_DB_PASSWORD=${UNIFI_DB_PASSWORD}

NOSQL_CREDENTIALS="\${UNIFI_DB_NAME}:\${UNIFI_DB_USER}:\${UNIFI_DB_PASSWORD}"

ENCRYPTION_KEY=${ENCRYPTION_KEY}

GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET}
GARAGE_BUCKETS=${GARAGE_BUCKETS_CSV}

TMP_S3_CREDENTIALS_FILE=${TMP_S3_CREDENTIALS_FILE}

CERTS_DIR=${CERTS_DIR}
LOG_DIR=${LOG_DIR}
BACKUP_DIR=${BACKUP_DIR}

BACKUP_BUCKET=${BACKUP_BUCKET}
S3_MOUNT_DIR=${S3_MOUNT_DIR}

PUID=1000
PGID=1000
TZ=${TZ}

NoteAuthCode=${NOTE_PIN}
EOF

  chmod 600 "$env_file"

  log ".env-local created"
}

#==============================================================================#
#                               Main function
#==============================================================================#

main() {
  check_os
  check_deps
  sync_repo
  
  configure_storage
  create_keepass_db
  generate_env
  
  discover_services
  choose_services
  install_scripts
  link_units
  generate_overrides

  systemctl daemon-reload

  log "installation complete"
  log "enable backups:      systemctl enable --now anode-backup.timer"
  log "enable auto-suspend: systemctl enable --now anode-suspend.timer (check Wake-on-LAN first, see README)"
}

#==============================================================================#
#                                Entry point
#==============================================================================#
if [[ "${SCRIPT_NAME}" == "$0" ]]; then main "$@"; fi