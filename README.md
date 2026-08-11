# rachels-turk

An integration engine: it pulls data from several places, merges it, and emits
it in the shape Rachel needs.

**Status: skeleton.** There are no integrations in here yet — the spec is still
to come. What exists today is the scaffolding: a service that starts, answers
`/api/health`, and can be deployed to and rolled back on the Raspberry Pi.

## What runs where

| | |
|---|---|
| Runs on | Raspberry Pi, `192.168.1.119`, user `trevor` |
| Service | `rachels-turk` (systemd, starts on boot) |
| Install dir | `/home/trevor/rachels-turk` — replaced wholesale by every deploy |
| Data dir | `/home/trevor/rachels-turk-data` — survives deploys and rollbacks |
| Port | 3100 |
| Health | `http://192.168.1.119:3100/api/health` |

Anything the engine must not lose belongs in the data dir. The install dir is
disposable by design: a deploy extracts over it and a rollback replaces it.

## Locally

```bash
npm start          # http://localhost:3100/api/health
npm test
```

No dependencies yet, so there is nothing to install.

## Deploying

Once, on a fresh Pi — installs Node if needed, creates the directories, and
installs and enables the systemd unit:

```bash
tools/provision.sh
```

After that, every deploy is:

```bash
tools/deploy.sh
```

That runs the test suite, refuses to continue if it fails, tars up the service,
backs up the current release on the Pi, extracts the new one, reinstalls
dependencies only if they actually moved, restarts the service, and checks
`/api/health` before calling it done.

| | |
|---|---|
| `tools/deploy.sh --dry-run` | print every step, change nothing |
| `tools/deploy.sh --skip-tests` | deploy without running the suite |
| `tools/deploy.sh --rollback` | put the Pi back on the previous release |
| `tools/deploy.sh --logs` | tail the service log on the Pi |

The last 5 releases are kept in `/home/trevor/rachels-turk-releases`.

### Settings

Hostnames and paths live in `tools/deploy.conf`, which is gitignored — copy
`tools/deploy.conf.example` and edit. Every value has a working default, so an
empty file is fine; set only what differs. Environment variables beat the file,
so a one-off is just:

```bash
PI_HOST=trevor@192.168.1.50 tools/deploy.sh
```

### Secrets

Credentials for the upstream data sources go in `/home/trevor/rachels-turk/.env`
on the Pi. The systemd unit reads it if it is there and starts fine if it is
not. It is never in the repo and never in a deploy payload — which does mean a
rollback will not restore it, so keep a copy somewhere.

## Troubleshooting

```bash
tools/deploy.sh --logs
```

If the service will not start, that log says why. `systemctl status
rachels-turk` on the Pi is the other half. To get back to something that
worked:

```bash
tools/deploy.sh --rollback
```

## Layout

```
src/index.js       the service — today, just /api/health
test/              node --test suite; deploy.sh runs it first
tools/deploy.sh    deploy, rollback, logs
tools/provision.sh one-time Pi setup
deploy/*.service   systemd unit template, filled in by provision.sh
```
