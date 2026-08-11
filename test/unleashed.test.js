'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { sign } = require('../src/sources/unleashed.js');

// Fixed vectors, so a refactor that changes the encoding, the digest or the
// handling of the empty query fails here rather than as a 403 from Unleashed
// with an empty body. Generated with the same algorithm the sample client
// uses: HMAC-SHA256 over the query string, base64.
const KEY = 'test-key-not-a-real-one';

test('signs a query string', () => {
  assert.equal(sign('pageSize=200', KEY), 'hiAbzQRYNtBNzZKysOne7lSpZNybXbDjGSJzO10xD1g=');
});

test('signs the empty query — what a POST with no params sends', () => {
  assert.equal(sign('', KEY), 'O2sF63u6xcBDhahOFzamfoVuNU1vE1DvJsFCxmHr49c=');
});

test('the whole query string is signed, separators and all', () => {
  assert.equal(
    sign('pageSize=200&modifiedSince=2026-01-01', KEY),
    'VHh0PmR1PsXFSslzkR9MTD7978YjrBNxeRBotVGkggs='
  );
});

test('order matters — the literal string is signed, not a sorted one', () => {
  assert.notEqual(
    sign('a=1&b=2', KEY),
    sign('b=2&a=1', KEY),
    'if these ever match, something is normalising the query before signing'
  );
});
