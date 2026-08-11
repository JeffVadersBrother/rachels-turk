'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { server } = require('../src/index.js');

// Port 0 so the suite never collides with a service already running locally.
test('health endpoint answers ok', async (t) => {
  await new Promise((resolve) => server.listen(0, resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const { port } = server.address();
  const res = await fetch(`http://127.0.0.1:${port}/api/health`);
  assert.equal(res.status, 200);

  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.service, 'rachels-turk');
});

test('unknown paths 404 rather than hanging', async (t) => {
  await new Promise((resolve) => server.listen(0, resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const { port } = server.address();
  const res = await fetch(`http://127.0.0.1:${port}/nope`);
  assert.equal(res.status, 404);
});
