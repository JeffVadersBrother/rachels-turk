// Placeholder service. There is no integration work here yet — the app spec is
// still to come. What it does have is /api/health, because the deploy script
// asks the Pi for that after every restart and a deploy you cannot verify is
// not much of a deploy.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 3100);

// Written by tools/deploy.sh into the install directory. Reading it here means
// /api/health can tell you which commit is actually running on the Pi, rather
// than which commit you believe you deployed.
function deployed() {
  try {
    const raw = fs.readFileSync(path.join(__dirname, '..', 'DEPLOYED'), 'utf8');
    return Object.fromEntries(
      raw.split('\n').filter(Boolean).map((line) => {
        const i = line.indexOf('=');
        return i === -1 ? [line, ''] : [line.slice(0, i), line.slice(i + 1)];
      })
    );
  } catch {
    return {}; // running from a checkout, not a deploy
  }
}

const startedAt = new Date().toISOString();

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (url.pathname === '/api/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      service: 'rachels-turk',
      version: require('../package.json').version,
      startedAt,
      uptimeSeconds: Math.round(process.uptime()),
      build: deployed(),
    }));
    return;
  }

  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found\n');
});

if (require.main === module) {
  server.listen(PORT, () => {
    console.log(`rachels-turk listening on ${PORT}`);
  });
}

module.exports = { server, PORT };
