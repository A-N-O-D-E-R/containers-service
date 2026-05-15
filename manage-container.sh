#!/bin/bash

set -euo pipefail

script_path=$(realpath "$0")
dir=$(dirname "$script_path")

usage() {
  echo "Usage: $0 <command> <app-name|*> <env>"
  echo "Commands: start, stop"
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

setup_local_requirements() {
  local domain="anode.com"
  source "$env_file"
  local cert_dir="$CERTS_DIR"
  local hosts=(
    "sso.anode.com"
    "id.anode.com"
    "monitor.anode.com"
    "git.anode.com"
    "s3.anode.com"
    "portainer.anode.com"
    "note.anode.com"
    "search.anode.com"
    "cad.anode.com"
    "deluge.anode.com"
    "sabnzbd.anode.com"
    "zabbix.anode.com"
    "rss.anode.com"
    "unifi.anode.com"
    "sonarr.anode.com"
    "radarr.anode.com"
    "bazarr.anode.com"
    "overseerr.anode.com"
    "lidarr.anode.com"
    "prowlarr.anode.com"
    "homeassistant.anode.com"
    "tv.anode.com"
  )

  if ! command -v mkcert >/dev/null 2>&1; then
    echo "Error: mkcert is not available."
    exit 1
  fi

  if [ ! -f "$(mkcert -CAROOT)/rootCA.pem" ]; then
    mkcert -install
  fi

  mkdir -p "$cert_dir"

  if [ ! -f "$cert_dir/_wildcard.${domain}+1.pem" ]; then
    mkcert "*.${domain}" "$domain"
    mv ./*.pem "$cert_dir/" 2>/dev/null || true
    mv ./*.key "$cert_dir/" 2>/dev/null || true
  fi

  export CA_BUNDLE="$(mkcert -CAROOT)/rootCA.pem"

  for host in "${hosts[@]}"; do
    if ! grep -q "127.0.0.1 $host" /etc/hosts; then
      echo "127.0.0.1 $host" | sudo tee -a /etc/hosts > /dev/null
    fi
  done

  echo "Setup complete"
}

if [[ "$env" == "local" ]]; then
  setup_local_requirements
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
      echo "Starting '$app_name' ($env)..."
      compose_cmd "$app_name" "$compose_file" up -d
      ;;
    stop)
      echo "Stopping '$app_name' ($env)..."
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
  # Enforce start order: traefik → db → rest (reversed for stop)
  priority=(traefik db cache)
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
  if [[ "$command" == "stop" ]]; then
    mapfile -t apps < <(printf '%s\n' "${ordered[@]}" | tac)
  else
    apps=("${ordered[@]}")
  fi
  for a in "${apps[@]}"; do
    run_for_app "$a"
  done
else
  case "$command" in
    start|stop) run_for_app "$app" ;;
    *)
      echo "Error: Unknown command '$command'"
      usage
      ;;
  esac
fi
