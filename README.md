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

Credentials for the upstream data sources go in `.env` — one beside the repo
for local work, one at `/home/trevor/rachels-turk/.env` on the Pi, which the
systemd unit reads if it is there and starts fine without. Copy `.env.example`
and fill it in. `.env` is gitignored and never goes in a deploy payload, which
also means a rollback will not restore it, so keep a copy somewhere.

## Sources

### Unleashed

`src/sources/unleashed.js`. Set `UNLEASHED_API_ID` and `UNLEASHED_API_KEY`, then
prove they work before building anything on top:

```bash
node --env-file=.env src/sources/unleashed.js Products
```

```js
const { request, paginate, all } = require('./src/sources/unleashed.js');

const first = await request('Products', { params: { pageSize: 50 }, page: 1 });
const customers = await all('Customers');
for await (const invoices of paginate('SalesInvoices', { modifiedSince: '2026-01-01' })) {
  // a page at a time, so the whole ledger is never in memory at once
}
```

Two things about Unleashed's auth that are easy to get wrong and give you a
bare 403 with nothing in the body:

- The `api-auth-signature` header is an HMAC-SHA256 of **the query string
  alone** — not the URL, not the path, and without the leading `?`. A request
  with no query string signs the empty string. The signed string and the sent
  string have to match byte for byte, so the module builds it once and uses
  that one value for both.
- Pagination is on the **path**, not the query: `/Products/2?pageSize=200`. The
  page number is therefore outside the signature and `pageSize` is inside it.

`pageSize` caps at 200. Ask for more and you get 200 anyway, with nothing to
say so — which reads as "that was all the data" and quietly truncates a sync.

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
