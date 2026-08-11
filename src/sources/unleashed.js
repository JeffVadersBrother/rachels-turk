// Unleashed API client.
//
// Auth is two headers: the API id in the clear, and an HMAC-SHA256 of the
// QUERY STRING keyed with the API key, base64. Not the URL, not the path —
// just the bit after the ?, without the ? itself. No query string means you
// sign the empty string.
//
// Because of that, the string that gets signed and the string that gets sent
// have to be byte-identical: a space encoded as %20 in one and + in the other
// is a 403 with nothing in the body to tell you why. So the query is built
// exactly once, below, and both the signature and the URL come from that one
// variable. Don't reformat it in between.
'use strict';

const crypto = require('node:crypto');

const API_HOST = process.env.UNLEASHED_API_HOST || 'https://api.unleashedsoftware.com';

// Unleashed's own cap. Asking for more is not an error, you just silently get
// 200, which looks like "that's all the data" and quietly truncates a sync.
const MAX_PAGE_SIZE = 200;

function credentials() {
  const id = process.env.UNLEASHED_API_ID;
  const key = process.env.UNLEASHED_API_KEY;
  if (!id || !key) {
    throw new Error(
      'UNLEASHED_API_ID and UNLEASHED_API_KEY must be set — see .env.example'
    );
  }
  return { id, key };
}

/** HMAC-SHA256 of the query string, base64. Exported for the test. */
function sign(query, key) {
  return crypto.createHmac('sha256', key).update(query, 'utf8').digest('base64');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * One request to Unleashed.
 *
 * @param {string} resource   e.g. 'Products', 'SalesInvoices'
 * @param {object} [opts]
 * @param {object} [opts.params]  query params — these ARE signed
 * @param {number} [opts.page]    page number; goes in the path, NOT signed
 * @param {string} [opts.method]  default GET
 * @param {object} [opts.body]    JSON body for POST/PUT
 * @param {number} [opts.retries] attempts on 429/5xx, default 3
 */
async function request(resource, opts = {}) {
  const { params = {}, page, method = 'GET', body, retries = 3 } = opts;
  const { id, key } = credentials();

  // Built once. Signed and sent as the same string — see the note up top.
  const query = new URLSearchParams(params).toString();

  // Page number is part of the path (/Products/2), so it is outside the
  // signature. pageSize is a normal query param, so it is inside it.
  const path = page ? `${resource}/${page}` : resource;
  const url = query ? `${API_HOST}/${path}?${query}` : `${API_HOST}/${path}`;

  const headers = {
    'api-auth-id': id,
    'api-auth-signature': sign(query, key),
    Accept: 'application/json',
    'Content-Type': 'application/json',
  };

  let lastError;
  for (let attempt = 1; attempt <= retries; attempt++) {
    const res = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    if (res.ok) return res.json();

    const text = await res.text().catch(() => '');

    // Unleashed rate-limits, and a Pi walking every page of every resource
    // will find that limit. Retry those and genuine server faults; anything
    // else is our mistake and retrying just makes the same request again.
    if (res.status === 429 || res.status >= 500) {
      lastError = new Error(`Unleashed ${res.status} on ${path}: ${text.slice(0, 200)}`);
      if (attempt < retries) {
        // Honour Retry-After when it is sent, otherwise back off.
        const after = Number(res.headers.get('retry-after'));
        await sleep(Number.isFinite(after) && after > 0 ? after * 1000 : 2 ** attempt * 1000);
        continue;
      }
      throw lastError;
    }

    // 403 here is almost always the signature rather than the credentials:
    // the query string that was signed did not match the one that was sent.
    throw new Error(`Unleashed ${res.status} on ${path}: ${text.slice(0, 500)}`);
  }
  throw lastError;
}

/**
 * Walk every page of a resource, yielding each page's Items array.
 *
 *   for await (const products of paginate('Products')) { ... }
 *
 * Yields pages rather than returning one big array because the whole product
 * catalogue in memory on a Pi is a different problem to have.
 */
async function* paginate(resource, params = {}) {
  const pageSize = Math.min(Number(params.pageSize) || MAX_PAGE_SIZE, MAX_PAGE_SIZE);
  let page = 1;
  let lastPage = 1;

  do {
    const body = await request(resource, { params: { ...params, pageSize }, page });
    // Unleashed wraps collections as { Pagination: {...}, Items: [...] }.
    yield body.Items || [];
    lastPage = body.Pagination ? body.Pagination.NumberOfPages : page;
    page++;
  } while (page <= lastPage);
}

/** Every item of a resource, flattened. Fine for small collections. */
async function all(resource, params = {}) {
  const items = [];
  for await (const page of paginate(resource, params)) items.push(...page);
  return items;
}

module.exports = { request, paginate, all, sign, API_HOST, MAX_PAGE_SIZE };

// Smoke check, so you can prove the credentials work before writing anything
// that depends on them:
//
//   node --env-file=.env src/sources/unleashed.js Products
//
if (require.main === module) {
  const resource = process.argv[2] || 'Products';
  request(resource, { params: { pageSize: 1 }, page: 1 })
    .then((body) => {
      const n = body.Pagination ? body.Pagination.NumberOfItems : (body.Items || []).length;
      console.log(`ok — ${resource}: ${n} items visible`);
      console.log(JSON.stringify(body.Items ? body.Items[0] : body, null, 2).slice(0, 800));
    })
    .catch((err) => {
      console.error(err.message);
      process.exit(1);
    });
}
