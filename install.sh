#!/bin/bash
set -euo pipefail

script_path=$(realpath "$0")
dir=$(dirname "$script_path")
systemd_dest="/etc/systemd/system"

EXCLUDED=(traefik db cache)

check_os() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: Linux required" >&2
    exit 1
  fi
  if ! systemctl --version &>/dev/null 2>&1; then
    echo "error: systemd required" >&2
    exit 1
  fi
  if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
  fi
}

check_deps() {
  local missing=()

  command -v docker &>/dev/null || missing+=(docker)
  if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
    missing+=(docker-compose)
  fi

  command -v mkcert &>/dev/null || echo "warning: mkcert not found, required for local env"
  command -v s3fs &>/dev/null || echo "warning: s3fs not found, required for local env"

  [[ ${#missing[@]} -eq 0 ]] && return 0

  echo "missing dependencies: ${missing[*]}"

  local pm=""
  if command -v apt-get &>/dev/null; then pm="apt-get"
  elif command -v dnf &>/dev/null; then pm="dnf"
  elif command -v pacman &>/dev/null; then pm="pacman"
  else
    echo "error: unsupported package manager, install manually: ${missing[*]}" >&2
    exit 1
  fi

  read -rp "install missing deps via $pm? [y/N] " reply
  [[ "${reply,,}" == "y" ]] || { echo "error: install dependencies manually and re-run" >&2; exit 1; }

  case "$pm" in
    apt-get) apt-get install -y docker.io docker-compose-v2 ;;
    dnf)     dnf install -y docker docker-compose-plugin ;;
    pacman)  pacman -S --noconfirm docker docker-compose ;;
  esac

  systemctl enable --now docker
}

is_excluded() {
  local app="$1"
  for e in "${EXCLUDED[@]}"; do [[ "$app" == "$e" ]] && return 0; done
  return 1
}

needs_db() {
  local app="$1"
  grep -ql "shared-db" "$dir/$app"/compose-*.yml 2>/dev/null
}

needs_cache() {
  local app="$1"
  grep -ql "shared-cache" "$dir/$app"/compose-*.yml 2>/dev/null
}

link_units() {
  for unit in "$dir"/*.service "$dir"/*.target; do
    [[ -e "$unit" ]] || continue
    dest="$systemd_dest/$(basename "$unit")"
    ln -sf "$unit" "$dest"
    echo "linked $dest -> $unit"
  done
}

generate_overrides() {
  declare -A seen
  local apps=()
  for f in "$dir"/*/compose-*.yml; do
    app=$(basename "$(dirname "$f")")
    [[ -z "${seen[$app]+x}" ]] && apps+=("$app") && seen[$app]=1
  done

  for app in "${apps[@]}"; do
    is_excluded "$app" && continue

    drop_in="$systemd_dest/anode-container@${app}.service.d/order.conf"
    mkdir -p "$(dirname "$drop_in")"

    local after="anode-container@traefik.service"
    local requires=""

    needs_db "$app" && after+=" anode-container@db.service" && requires+=" anode-container@db.service"
    needs_cache "$app" && after+=" anode-container@cache.service" && requires+=" anode-container@cache.service"

    {
      echo "[Unit]"
      echo "After=${after}"
      [[ -n "$requires" ]] && echo "Requires=${requires}"
    } > "$drop_in"

    echo "wrote $drop_in"
  done
}

check_os
check_deps
sudo install -m 755 ./manage-container.sh /usr/local/bin/anode-container
link_units
generate_overrides
systemctl daemon-reload
echo "done"
