# Containers

Self-hosted services managed via Docker Compose, orchestrated by `manage-container.sh`.

## Structure

Each service lives in its own folder with environment-specific compose files:

```
<app>/
  compose-local.yml   # local dev (mkcert TLS, no ACME)
  compose-prod.yml    # production (Let's Encrypt via Traefik)
```

## manage-container.sh

```
./manage-container.sh <command> <app-name|*> <env>
```

| Argument | Values |
|---|---|
| `command` | `start`, `stop` |
| `app-name` | folder name, or `*` for all apps |
| `env` | `local`, `prod` |

When `env` is `local`, the script automatically runs the local setup (mkcert certs, `/etc/hosts` entries) before starting containers.

## Systemd integration

All systemd files live under `systemd/`:

```
systemd/
  anode.target                              # starts all services in order
  anode-container@.service                  # template for a single app
  anode-container@<app>.service.d/
    order.conf                              # per-app After=/Requires= overrides
```

Start order enforced: **traefik → db → everything else**.  
`forgejo` and `zabbix` additionally `Requires=` db (hard dependency).

### Install

Copy the template, target, and all drop-in directories to `/etc/systemd/system/`, then reload:

```bash
sudo cp systemd/anode-container@.service /etc/systemd/system/
sudo cp systemd/anode.target /etc/systemd/system/
sudo cp -r systemd/anode-container@*.service.d /etc/systemd/system/
sudo systemctl daemon-reload
```

### Start all services

```bash
sudo systemctl enable --now anode.target
```

This enables and starts every service in the correct order in one command.

### Start/stop a single app

```bash
sudo systemctl start anode-container@forgejo
sudo systemctl stop anode-container@forgejo
```

### Override env (e.g. local)

```bash
sudo systemctl edit anode-container@forgejo
```

Add:

```ini
[Service]
Environment=ENV=local
```

> `Type=oneshot` + `RemainAfterExit=yes` is used because `manage-container.sh` exits after launching detached containers — systemd treats the unit as active until an explicit stop.

## Local setup requirements

Running with `env=local` requires:

- `mkcert` (installed automatically if missing)
- Sudo access (for `/etc/hosts` entries and Docker)
- A `.env-local` file at the repo root with at least `CERTS_DIR` defined
