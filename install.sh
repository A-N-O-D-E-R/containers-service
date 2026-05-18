#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/A-N-O-D-E-R/containers-service.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/anode}"
BRANCH="${BRANCH:-master}"

SYSTEMD_DIR="/etc/systemd/system"
EXCLUDED=(traefik db cache)

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
    || warn "mkcert not installed (needed for local TLS)"

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

  for unit in "$INSTALL_DIR"/*.service "$INSTALL_DIR"/*.target; do
    local dest="$SYSTEMD_DIR/$(basename "$unit")"

    ln -sf "$unit" "$dest"

    log "linked $(basename "$dest")"
  done
}

generate_overrides() {
  declare -A seen
  local apps=()

  for f in "$INSTALL_DIR"/*/compose-*.yml; do
    local app
    app=$(basename "$(dirname "$f")")

    if [[ -z "${seen[$app]+x}" ]]; then
      apps+=("$app")
      seen[$app]=1
    fi
  done

  for app in "${apps[@]}"; do
    is_excluded "$app" && continue

    local dropin="$SYSTEMD_DIR/anode-container@${app}.service.d/order.conf"

    mkdir -p "$(dirname "$dropin")"

    local after="anode-container@traefik.service"
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

install_scripts() {
  install -m 755 \
    "$INSTALL_DIR/manage-container.sh" \
    /usr/local/bin/anode-container
}

main() {
  check_os
  check_deps
  sync_repo
  install_scripts
  link_units
  generate_overrides

  systemctl daemon-reload

  log "installation complete"
}

main "$@"