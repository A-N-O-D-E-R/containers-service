# Containers

Self-hosted services managed via Docker Compose, orchestrated by `manage-container.sh`.
Energy-sober design adapted from [sober-selfhost](https://github.com/mbaelde/sober-selfhost):
heavy services sleep until requested, and the whole host suspends when idle.

| Component | Role |
|---|---|
| Traefik (`traefik/`) | Reverse proxy, HTTPS (mkcert wildcard), label routing, Sablier plugin |
| Sablier (`sablier/`) | Starts gated containers on request, stops them after 30 min idle |
| Tailscale (host) | Remote access to the private `anode.com` |
| `scripts/backup.sh` | DB dumps + `rclone sync` to an encrypted `crypt` remote |
| `scripts/auto-suspend.sh` | Suspends the host when idle |
| `scripts/wol-relay.sh` | Wakes the host, run from an always-on LAN device |

## Structure

Each service lives in its own folder with environment-specific compose files:

```
<app>/
  compose-local.yml   # dev machine (/etc/hosts -> 127.0.0.1)
  compose-prod.yml    # server (reached over Tailscale)
```

Both envs use the same TLS: `anode.com` is not publicly reachable, so there is
no Let's Encrypt. `manage-container.sh` creates a mkcert wildcard
`*.anode.com` in `CERTS_DIR`, loaded by `traefik/dynamic.yml`.

## manage-container.sh

```
./manage-container.sh <command> <app-name|*> <env>
```

| Argument | Values |
|---|---|
| `command` | `start`, `stop` (keeps containers), `down` (removes containers) |
| `app-name` | folder name, or `*` for all apps |
| `env` | `local`, `prod` |

`start` creates the mkcert certificate if missing; with `local` it also adds `/etc/hosts` entries.
Start order with `*`: traefik → sablier → db → cache → nosql → garage → rest (reversed for stop/down).

> Use `stop`, not `down`, for gated apps: Sablier only starts containers that
> exist. After a `down`, run `start` again to recreate them.

## On-demand containers (Sablier)

Gated apps carry these labels (Traefik ≥ 3.6 needed for `allownonrunning`):

```yaml
labels:
  - "sablier.enable=true"
  - "sablier.group=immich"                      # on every container of the stack
  - "traefik.docker.allownonrunning=true"       # keep the route while stopped
  - "traefik.http.routers.immich.middlewares=immich-sablier"
  - "traefik.http.middlewares.immich-sablier.plugin.sablier.sablierUrl=http://sablier:10000"
  - "traefik.http.middlewares.immich-sablier.plugin.sablier.group=immich"
  - "traefik.http.middlewares.immich-sablier.plugin.sablier.sessionDuration=30m"
  - "traefik.http.middlewares.immich-sablier.plugin.sablier.blocking.timeout=5m"   # or dynamic.displayName=...
```

| Gated (sleep after 30 min idle) | Strategy |
|---|---|
| gitlab, immich, posthog, jellyfin | `blocking`: git / mobile / SDK clients wait instead of getting an HTML page |
| penpot, documenso, calcom, freecad, note, portainer, searxng, zabbix-web | `dynamic`: browser waiting page |

Always on: traefik, sablier, shared-db/cache/nosql, garage (s3fs mount), forgejo
(SSH 2222), n8n (cron/webhooks), listmonk (scheduled campaigns), unifi,
homeassistant, the *arr apps and download clients (scheduled jobs, and they
call each other directly, bypassing Traefik), pocket-id/authelia, zabbix-server
(keeps collecting).

Sablier honours compose `depends_on` inside a project. Containers started by
`compose up`, a restart policy, or a reboot get one 30 min session, then sleep
(`--provider.auto-warm-externally-started`). Never use `restart: always` on a
gated container.

Gotcha (from sober-selfhost): a gated container with a red healthcheck makes
Sablier hold every request. If an image declares a healthcheck, inherit it.
Don't write your own.

## Remote access (Tailscale + private DNS)

1. Install Tailscale on the server (`tailscale up`) and on your devices.
2. Serve `*.anode.com` → server's Tailscale IP from a resolver on an
   **always-on** device (the WoL relay, so DNS still answers while the server sleeps),
   e.g. dnsmasq: `address=/anode.com/100.x.y.z`.
3. Tailscale admin → DNS → *Add nameserver* → that device's Tailscale IP,
   *Restrict to domain* `anode.com` (split DNS).
4. Install the mkcert root CA (`$(mkcert -CAROOT)/rootCA.pem` on the server) on
   every client: OS / browser trust store, and on phones as a user CA profile.

Traefik dashboard: `https://traefik.anode.com`, basic auth from
`TRAEFIK_DASHBOARD_AUTH` (`htpasswd -nB admin`, single-quoted in the env file).

## Backups (rclone crypt)

```bash
rclone config   # 1) remote "offsite" (s3/b2/sftp/...)
                # 2) remote "offsite-crypt", type crypt, remote = offsite:anode-backup
                # keep both crypt passwords somewhere else than this server
sudo anode-backup prod              # manual run
sudo systemctl enable --now anode-backup.timer   # daily 03:00, catches up after suspend
```

Dumps `shared-db`, `immich-postgres`, `penpot-postgres`, `posthog-db` (pg_dumpall),
`shared-nosql` (mongodump), `shared-cache` (SAVE). It starts sleeping DB containers
if needed; Sablier stops them again later. Synced to `$RCLONE_REMOTE`:
- `infra`: `BACKUP_DIR`, without the live DB files; garage metadata comes from its 6h snapshots
- `data`: `S3_DATA_DIR`
- `certs`
- `mkcert-ca`, if `MKCERT_CAROOT` is set
- the env file

rclone runs as root, so configure it as root (or set `RCLONE_CONFIG`).
Not covered: Docker named volumes other than the DB dumps
(penpot assets, posthog clickhouse/kafka/minio).

## Auto-suspend and Wake-on-LAN

`anode-suspend` runs every 5 min and suspends after `SUSPEND_IDLE_MINUTES` (default 20) when:
- no gated container is running
- no client connection to Traefik
- no logged-in user (`who`)
- no backup running
- no `SUSPEND_BLOCKERS` container running

Test it with `sudo anode-suspend prod --dry-run`.

**Suspend stops everything**, always-on services included (n8n cron,
homeassistant, unifi, seeding). List the ones that must keep the host awake in
`SUSPEND_BLOCKERS`.

Server, once:
- BIOS: enable Wake-on-LAN / "Power On By PCI-E".
- NIC: `nmcli con modify <profile> 802-3-ethernet.wake-on-lan magic` (verify `ethtool <iface>` → `Wake-on: g`).

Wake it from anywhere through an always-on LAN device:

```bash
ssh relay ./wol-relay.sh <server-MAC> 192.168.1.255   # relay needs `wakeonlan`
```

Then:

```bash
sudo systemctl enable --now anode-suspend.timer
```

## Systemd integration

Unit files live at the repo root and are symlinked by `install.sh`:

```
anode-container@.service   # one app: anode-container start|stop <app> ${ENV}
anode-backup.service/.timer
anode-suspend.service/.timer
```

```bash
sudo ./install.sh   # links units + /usr/local/bin/anode-{container,backup,suspend}, writes order drop-ins
```

`install.sh` writes `anode-container@<app>.service.d/order.conf` per app:
`After=` traefik and sablier, plus `Requires=` db/cache for apps using `shared-db`/`shared-cache`.

```bash
sudo systemctl start anode-container@forgejo
sudo systemctl stop anode-container@forgejo
```

Units default to `ENV=local`. On the server, override each one:

```bash
sudo systemctl edit anode-container@forgejo   # same for anode-backup / anode-suspend
```

```ini
[Service]
Environment=ENV=prod
```

> `Type=oneshot` + `RemainAfterExit=yes` is used because `manage-container.sh` exits after launching detached containers — systemd treats the unit as active until an explicit stop.

## Local setup requirements

- `mkcert`
- Sudo access (for `/etc/hosts` entries and Docker)
- A `.env-<env>` file at the repo root, see `.env.exemple` (at least `CERTS_DIR`)

## S3
When starting the garage service (S3) you will need to add

- in ~/.aws/config
```toml
[default]
region = garage
output = json

services = garage-s3

[services garage-s3]
s3 =
  endpoint_url = https://s3.anode.com
```

in your bashrc/zshrc or whatever

```bash
export AWS_CA_BUNDLE="${CA_BUNDLE:-$HOME/.local/share/mkcert/rootCA.pem}"
```

# tests 
```bash
bats .tests/install.bats
```
