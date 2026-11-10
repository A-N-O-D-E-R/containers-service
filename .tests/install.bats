#!/usr/bin/env bats
# bats-core: https://github.com/bats-core/bats-core
# Install: git clone --depth 1 https://github.com/bats-core/bats-core /tmp/bats && sudo /tmp/bats/install.sh /usr/local

setup() {
  TMPDIR="$(mktemp -d)"
  INSTALL_DIR="$TMPDIR/install"
  mkdir -p "$INSTALL_DIR"
  export INSTALL_DIR TMPDIR

  MOCKBIN="$(mktemp -d)"
  _ORIGINAL_PATH="$PATH"
  export PATH="$MOCKBIN:$PATH"

  # Source functions without running main (BASH_SOURCE guard in install.sh)
  source "$BATS_TEST_DIRNAME/../install.sh"

  AVAILABLE_SERVICES=()
  SELECTED_SERVICES=()
}

teardown() {
  rm -rf "$TMPDIR" "$MOCKBIN"
  export PATH="$_ORIGINAL_PATH"
}

mock_cmd() {  # mock_cmd <name> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$MOCKBIN/$1"
  chmod +x "$MOCKBIN/$1"
}

# ─── is_excluded ──────────────────────────────────────────────────────────────

@test "is_excluded: traefik is excluded" {
  is_excluded traefik
}

@test "is_excluded: db is excluded" {
  is_excluded db
}

@test "is_excluded: cache is excluded" {
  is_excluded cache
}

@test "is_excluded: regular app is not excluded" {
  ! is_excluded forgejo
}

@test "is_excluded: partial match is not excluded" {
  ! is_excluded "db-extra"
}

# ─── service_selected ─────────────────────────────────────────────────────────

@test "service_selected: returns 0 when service is in list" {
  SELECTED_SERVICES=(forgejo jellyfin sonarr)
  service_selected forgejo
}

@test "service_selected: returns 1 when service is absent" {
  SELECTED_SERVICES=(forgejo jellyfin)
  ! service_selected sonarr
}

@test "service_selected: returns 1 for empty list" {
  SELECTED_SERVICES=()
  ! service_selected forgejo
}

@test "service_selected: trims whitespace from selected service names" {
  SELECTED_SERVICES=(" forgejo " "  sonarr  ")
  service_selected forgejo
  service_selected sonarr
}

@test "service_selected: detects last service in list" {
  SELECTED_SERVICES=(alpha beta gamma)
  service_selected gamma
}

# ─── needs_db ─────────────────────────────────────────────────────────────────

@test "needs_db: detects shared-db reference in compose file" {
  mkdir -p "$INSTALL_DIR/myapp"
  printf 'host: shared-db:5432\n' > "$INSTALL_DIR/myapp/compose-local.yml"
  needs_db myapp
}

@test "needs_db: returns 1 when compose file has no shared-db reference" {
  mkdir -p "$INSTALL_DIR/myapp"
  printf 'services: {}\n' > "$INSTALL_DIR/myapp/compose-local.yml"
  ! needs_db myapp
}

@test "needs_db: finds reference across multiple compose files" {
  mkdir -p "$INSTALL_DIR/myapp"
  printf 'services: {}\n' > "$INSTALL_DIR/myapp/compose-local.yml"
  printf 'host: shared-db:5432\n' > "$INSTALL_DIR/myapp/compose-prod.yml"
  needs_db myapp
}

@test "needs_db: returns 1 when directory has no compose files" {
  mkdir -p "$INSTALL_DIR/myapp"
  ! needs_db myapp
}

# ─── needs_cache ──────────────────────────────────────────────────────────────

@test "needs_cache: detects shared-cache reference in compose file" {
  mkdir -p "$INSTALL_DIR/myapp"
  printf 'redis: shared-cache\n' > "$INSTALL_DIR/myapp/compose-prod.yml"
  needs_cache myapp
}

@test "needs_cache: returns 1 when no shared-cache reference" {
  mkdir -p "$INSTALL_DIR/myapp"
  printf 'services: {}\n' > "$INSTALL_DIR/myapp/compose-prod.yml"
  ! needs_cache myapp
}

@test "needs_cache: returns 1 when no compose files" {
  mkdir -p "$INSTALL_DIR/myapp"
  ! needs_cache myapp
}

# ─── discover_services ────────────────────────────────────────────────────────

@test "discover_services: populates AVAILABLE_SERVICES from compose files" {
  mkdir -p "$INSTALL_DIR/alpha" "$INSTALL_DIR/beta"
  touch "$INSTALL_DIR/alpha/compose-local.yml"
  touch "$INSTALL_DIR/beta/compose-prod.yml"

  discover_services

  [[ " ${AVAILABLE_SERVICES[*]} " == *" alpha "* ]]
  [[ " ${AVAILABLE_SERVICES[*]} " == *" beta "* ]]
}

@test "discover_services: deduplicates service with multiple compose files" {
  mkdir -p "$INSTALL_DIR/alpha"
  touch "$INSTALL_DIR/alpha/compose-local.yml"
  touch "$INSTALL_DIR/alpha/compose-prod.yml"

  discover_services

  local count=0
  for svc in "${AVAILABLE_SERVICES[@]}"; do
    [[ "$svc" == "alpha" ]] && ((count++)) || true
  done
  [ "$count" -eq 1 ]
}

@test "discover_services: ignores directories without compose files" {
  mkdir -p "$INSTALL_DIR/alpha" "$INSTALL_DIR/empty"
  touch "$INSTALL_DIR/alpha/compose-local.yml"
  touch "$INSTALL_DIR/empty/other-file.txt"

  discover_services

  [[ " ${AVAILABLE_SERVICES[*]} " == *" alpha "* ]]
  [[ " ${AVAILABLE_SERVICES[*]} " != *" empty "* ]]
}

# ─── choose_services ──────────────────────────────────────────────────────────

@test "choose_services: uses SERVICES env var (comma-separated)" {
  AVAILABLE_SERVICES=(forgejo jellyfin sonarr)
  SERVICES="forgejo,sonarr" choose_services

  [ "${#SELECTED_SERVICES[@]}" -eq 2 ]
  service_selected forgejo
  service_selected sonarr
  ! service_selected jellyfin
}

@test "choose_services: handles single service in SERVICES" {
  AVAILABLE_SERVICES=(forgejo jellyfin)
  SERVICES="forgejo" choose_services

  [ "${#SELECTED_SERVICES[@]}" -eq 1 ]
  service_selected forgejo
}

@test "choose_services: handles whitespace around names in SERVICES" {
  AVAILABLE_SERVICES=(forgejo jellyfin)
  SERVICES=" forgejo , jellyfin " choose_services

  service_selected forgejo
  service_selected jellyfin
}

# ─── sync_repo ────────────────────────────────────────────────────────────────

@test "sync_repo: clones repo when INSTALL_DIR has no .git" {
  mock_cmd git 'printf "%s\n" "$@" >> "'"$TMPDIR"'/git_calls"'

  sync_repo

  grep -q "clone" "$TMPDIR/git_calls"
}

@test "sync_repo: fetches and pulls when INSTALL_DIR already has .git" {
  mkdir -p "$INSTALL_DIR/.git"
  mock_cmd git 'printf "%s\n" "$@" >> "'"$TMPDIR"'/git_calls"'

  sync_repo

  grep -q "fetch" "$TMPDIR/git_calls"
  grep -q "pull"  "$TMPDIR/git_calls"
}

@test "sync_repo: fails when git returns non-zero" {
  mock_cmd git 'exit 1'

  run sync_repo
  [ "$status" -ne 0 ]
}

# ─── check_os ─────────────────────────────────────────────────────────────────

@test "check_os: fails when not running as root" {
  if [[ "$EUID" -eq 0 ]]; then
    skip "running as root"
  fi

  run check_os
  [ "$status" -ne 0 ]
}
