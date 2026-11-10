#!/bin/bash

set -euo pipefail

script_path=$(realpath "$0")
dir=$(dirname "$script_path")

usage() {
  echo "Usage: $0 <command> <app-name|*> <env>"
  echo "Commands: start, stop (keeps containers, required by Sablier), down (removes containers)"
  echo "Use '*' as app-name to target all apps for the given env."
  exit 1
}

if [[ $# -lt 3 ]]; then
  usage
fi

command="$1"
app="$2"
env="$3"
env_file="$dir/.env-${env}"

if [[ -f "$env_file" ]]; then
  set -a
  source "$env_file"
  set +a
fi

if ! sudo -n true 2>/dev/null; then
  echo "Error: This script requires sudo privileges. Please run as a user with sudo access."
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo "Error: Docker is not installed or not in PATH."
  exit 1
fi

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
  echo "Error: Docker Compose is not available."
  exit 1
fi

# anode.com is private (Tailscale / LAN only): both envs use the mkcert wildcard.
setup_certs() {
  local domain="anode.com"
  local cert_dir="${CERTS_DIR:?set CERTS_DIR in $env_file}"
  [[ -f "$cert_dir/_wildcard.${domain}+1.pem" ]] && return 0

  if ! command -v mkcert >/dev/null 2>&1; then
    echo "Error: mkcert is not available."
    exit 1
  fi

  if [ ! -f "$(mkcert -CAROOT)/rootCA.pem" ]; then
    mkcert -install
  fi

  mkdir -p "$cert_dir"
  (cd "$cert_dir" && mkcert "*.${domain}" "$domain")
  echo "Created wildcard certificate in $cert_dir (CA: $(mkcert -CAROOT)/rootCA.pem)"
}

setup_local_hosts() {
  local hosts=()
  while IFS= read -r host; do
    hosts+=("$host")
  done < <(find "$dir" -name "compose-local.yml" -exec grep -hoP "Host\(\`\K[^\`]+" {} \; | grep -v '<' | sort -u)

  for host in "${hosts[@]}"; do
    if ! grep -q "127.0.0.1 $host" /etc/hosts; then
      echo "127.0.0.1 $host" | sudo tee -a /etc/hosts > /dev/null
    fi
  done
}

if [[ "$command" == "start" ]]; then
  setup_certs
  [[ "$env" == "local" ]] && setup_local_hosts
fi

compose_cmd() {
  local app_name="$1"
  local compose_file="$2"
  shift 2
  if [[ ! -f "$env_file" ]]; then
    sudo docker compose -p "$app_name" -f "$compose_file" "$@"
  else
    sudo docker compose -p "$app_name" -f "$compose_file" --env-file "$env_file" "$@"
  fi
}


ensure_S3_mounted() {
  if sudo docker ps --format '{{.Names}}' | grep -qx 'garage'; then
    echo "garage is running, proceeding to mount S3 storage..."
  else
    echo "garage is NOT running"
    echo "Please start the 'garage' container service to access S3 storage features."
    exit 1
  fi
  local bucket="${BACKUP_BUCKET:-backup-bucket}"

  if [[ -f "${HOME}/.passwd-s3fs" ]]; then
    echo "S3 credentials file already exists at ${HOME}/.passwd-s3fs"
  else
    awk -F= '
    /aws_access_key_id/ { key=$2 }
    /aws_secret_access_key/ { secret=$2 }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      gsub(/^[ \t]+|[ \t]+$/, "", secret)
      print key ":" secret
    }
    ' ${TMP_S3_CREDENTIALS_FILE}/credentials > "${HOME}/.passwd-s3fs"
      chmod 600 "${HOME}/.passwd-s3fs"
      echo "Created S3 credentials file at ${HOME}/.passwd-s3fs"
  fi
  # Create mount dir if needed
  sudo mkdir -p "$S3_MOUNT_DIR"

  # Already mounted?
  if mountpoint -q "$S3_MOUNT_DIR"; then
    echo "S3 already mounted at $S3_MOUNT_DIR"
    return 0
  else
    echo "Mounting S3 bucket '$bucket' to $S3_MOUNT_DIR..."
  fi

  sudo s3fs "$bucket" "$S3_MOUNT_DIR" \
    -o passwd_file="${HOME}/.passwd-s3fs" \
    -o url="https://s3.anode.com" \
    -o endpoint=garage \
    -o logfile=/tmp/s3fs.log \
    -o use_path_request_style \
    -o allow_other \
    -o uid="${PUID}" \
    -o gid="${PGID}"

  # Verify mount succeeded
  if mountpoint -q "$S3_MOUNT_DIR"; then
    echo "Mounted $bucket to $S3_MOUNT_DIR"
    return 0
  else
    echo "Failed to mount $bucket"
    return 1
  fi
}

run_for_app() {
  local app_name="$1"
  local compose_file="$dir/$app_name/compose-${env}.yml"
  if [[ ! -f "$compose_file" ]]; then
    echo "Error: Compose file not found at '$compose_file'"
    exit 1
  fi
  case "$command" in
    start)
      sudo docker network ls | grep -q "anode-shared-network" || sudo docker network create anode-shared-network
      grep -q "S3_MOUNT_DIR" "$compose_file" && ensure_S3_mounted
      echo "Starting '$app_name' ($env)..."
      compose_cmd "$app_name" "$compose_file" up -d
      ;;
    stop)
      echo "Stopping '$app_name' ($env)..."
      compose_cmd "$app_name" "$compose_file" stop
      ;;
    down)
      echo "Removing '$app_name' ($env)..."
      compose_cmd "$app_name" "$compose_file" down
      ;;
  esac
}

if [[ "$app" == "*" ]]; then
  mapfile -t all_apps < <(
    for f in "$dir"/*/compose-${env}.yml; do
      [[ -f "$f" ]] && basename "$(dirname "$f")"
    done | sort
  )
  if [[ ${#all_apps[@]} -eq 0 ]]; then
    echo "Error: No compose-${env}.yml files found under '$dir'."
    exit 1
  fi
  # Enforce start order: traefik → sablier → db → s3 → rest (reversed for stop)
  priority=(traefik sablier db cache nosql garage)
  ordered=()
  for p in "${priority[@]}"; do
    for a in "${all_apps[@]}"; do
      [[ "$a" == "$p" ]] && ordered+=("$a")
    done
  done
  for a in "${all_apps[@]}"; do
    skip=false
    for p in "${priority[@]}"; do [[ "$a" == "$p" ]] && skip=true; done
    $skip || ordered+=("$a")
  done
  if [[ "$command" != "start" ]]; then
    mapfile -t apps < <(printf '%s\n' "${ordered[@]}" | tac)
  else
    apps=("${ordered[@]}")
  fi
  for a in "${apps[@]}"; do
    run_for_app "$a"
  done
else
  case "$command" in
    start|stop|down) run_for_app "$app" ;;
    *)
      echo "Error: Unknown command '$command'"
      usage
      ;;
  esac
fi
