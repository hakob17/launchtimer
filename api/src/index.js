// Launch Timer leaderboard API (Cloudflare Worker + D1).
//
//   GET  /v1/challenge                 → { challenge }                 one-time, for App Attest
//   POST /v1/attest   { device, keyId, attestation, challenge }        registers a device's key
//   POST /v1/runs     { payload: "<json>", assertion? }                posts a run's results
//   GET  /v1/board?metric=&make=&model=&country=&limit=               best result per driver+car
//   GET  /v1/me?metric=&device=                                       your best and your rank
//   POST /v1/report   { entry, device }                               flags an entry
//
// A post's payload is { device, handle, car: {make, model, year, trim}, country, run }. Posts
// signed with a registered App Attest key are marked verified; others still have to pass the
// same trace and physics checks.

import { verifyAttestation, verifyAssertion } from './attest.js';
import { validateRun, METRICS } from './validate.js';
import { validHandle, cleanCarText } from './names.js';

const HIDE_AFTER_REPORTS = 3;
const DEVICE = /^[0-9A-F-]{36}$/i;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};
const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors },
});
const fail = (message, status = 400) => json({ error: message }, status);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
    try {
      const route = `${request.method} ${url.pathname}`;
      switch (route) {
        case 'GET /': return new Response('Launch Timer leaderboard\n');
        case 'GET /v1/metrics': return json(METRICS);
        case 'GET /v1/challenge': return await challenge(env);
        case 'POST /v1/attest': return await attest(env, await request.json());
        case 'POST /v1/runs': return await postRun(env, await request.json());
        case 'GET /v1/board': return await board(env, url.searchParams);
        case 'GET /v1/me': return await me(env, url.searchParams);
        case 'POST /v1/report': return await report(env, await request.json());
        default: return fail('not found', 404);
      }
    } catch (error) {
      return fail(error.message || 'bad request');
    }
  },
};

async function challenge(env) {
  const value = crypto.randomUUID();
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM challenges WHERE created < ?').bind(now - 10 * 60_000),
    env.DB.prepare('INSERT INTO challenges (value, created) VALUES (?, ?)').bind(value, now),
  ]);
  return json({ challenge: value });
}

async function attest(env, body) {
  const { device, keyId, attestation, challenge } = body || {};
  if (!DEVICE.test(device || '') || !keyId || !attestation || !challenge) return fail('missing fields');
  const used = await env.DB.prepare('DELETE FROM challenges WHERE value = ? AND created > ? RETURNING value')
    .bind(challenge, Date.now() - 10 * 60_000).first();
  if (!used) return fail('challenge expired');
  const { publicKey, env: environment } = await verifyAttestation({ keyId, attestation, challenge });
  await env.DB.prepare(`INSERT INTO devices (id, key_id, public_key, counter, env, created) VALUES (?, ?, ?, 0, ?, ?)
    ON CONFLICT(id) DO UPDATE SET key_id = excluded.key_id, public_key = excluded.public_key, counter = 0, env = excluded.env`)
    .bind(device, keyId, publicKey, environment, Date.now()).run();
  return json({ ok: true, env: environment });
}

async function postRun(env, body) {
  if (typeof body?.payload !== 'string' || body.payload.length > 300_000) return fail('missing payload');
  const payload = JSON.parse(body.payload);
  const { device, handle, car, country, run } = payload;
  if (!DEVICE.test(device || '')) return fail('bad device');
  if (!validHandle(handle)) return fail('bad handle');
  const make = cleanCarText(car?.make, 40), model = cleanCarText(car?.model, 40), trim = cleanCarText(car?.trim, 24);
  const year = Number(car?.year);
  if (!make || !model || !(year >= 1950 && year <= new Date().getFullYear() + 2)) return fail('pick your car first');
  const region = /^[A-Z]{2}$/.test(country || '') ? country : null;
  if (typeof run?.id !== 'string' || run.id.length > 64) return fail('bad run id');

  const recent = await env.DB.prepare('SELECT COUNT(*) AS n FROM entries WHERE device = ? AND created > ?')
    .bind(device, Date.now() - 86_400_000).first();
  if (recent.n > 100) return fail('too many posts today, try tomorrow', 429);

  // A signed post from an attested device is verified; an unsigned one is accepted but not.
  let verified = 0;
  if (body.assertion) {
    const known = await env.DB.prepare('SELECT public_key, counter FROM devices WHERE id = ?').bind(device).first();
    if (known) {
      const counter = await verifyAssertion({
        publicKey: known.public_key, counter: known.counter, assertion: body.assertion,
        clientData: new TextEncoder().encode(body.payload),
      });
      await env.DB.prepare('UPDATE devices SET counter = ? WHERE id = ?').bind(counter, device).run();
      verified = 1;
    }
  }

  const { entries, grade } = validateRun(run);
  const now = Date.now();
  await env.DB.batch(entries.map(e => env.DB.prepare(
    `INSERT INTO entries (run_id, device, handle, make, model, year, trim, country, metric, value, verified, grade, created)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(run_id, metric) DO NOTHING`)
    .bind(run.id, device, handle, make, model, year, trim, region, e.metric, e.value, verified, grade, now)));

  const results = [];
  for (const e of entries) {
    results.push({
      metric: e.metric, value: e.value, verified: !!verified,
      overall: await rank(env, e.metric, e.value, {}),
      model: await rank(env, e.metric, e.value, { make, model }),
      country: region ? await rank(env, e.metric, e.value, { country: region }) : null,
    });
  }
  return json({ ok: true, results });
}

function filters(params) {
  const where = ['metric = ?', 'hidden = 0'], binds = [params.metric];
  if (params.make) { where.push('make = ?'); binds.push(params.make); }
  if (params.model) { where.push('model = ?'); binds.push(params.model); }
  if (params.country) { where.push('country = ?'); binds.push(params.country); }
  return { where: where.join(' AND '), binds };
}

/** Where `value` would place among each driver's best (per car), and out of how many. */
async function rank(env, metric, value, scope) {
  const { where, binds } = filters({ metric, ...scope });
  const row = await env.DB.prepare(
    `SELECT COALESCE(SUM(best < ?), 0) + 1 AS rank, COUNT(*) AS total
     FROM (SELECT MIN(value) AS best FROM entries WHERE ${where} GROUP BY device, make, model)`)
    .bind(value, ...binds).first();
  return { rank: row.rank, of: Math.max(row.total, row.rank) };
}

async function board(env, params) {
  const metric = params.get('metric');
  if (!METRICS[metric]) return fail('unknown metric');
  const limit = Math.min(100, Math.max(1, Number(params.get('limit')) || 50));
  const { where, binds } = filters({
    metric, make: params.get('make'), model: params.get('model'), country: params.get('country'),
  });
  const { results } = await env.DB.prepare(
    `SELECT id, handle, make, model, year, trim, country, value, verified, created FROM (
       SELECT *, ROW_NUMBER() OVER (PARTITION BY device, make, model ORDER BY value, created) AS rn
       FROM entries WHERE ${where})
     WHERE rn = 1 ORDER BY value, created LIMIT ?`)
    .bind(...binds, limit).all();
  return json({ metric, unit: METRICS[metric].unit, entries: results });
}

async function me(env, params) {
  const metric = params.get('metric'), device = params.get('device');
  if (!METRICS[metric] || !DEVICE.test(device || '')) return fail('bad request');
  const best = await env.DB.prepare(
    'SELECT value, make, model, country FROM entries WHERE metric = ? AND device = ? AND hidden = 0 ORDER BY value LIMIT 1')
    .bind(metric, device).first();
  if (!best) return json({ best: null });
  return json({
    best: best.value,
    overall: await rank(env, metric, best.value, {}),
    model: await rank(env, metric, best.value, { make: best.make, model: best.model }),
  });
}

async function report(env, body) {
  const entry = Number(body?.entry), device = body?.device;
  if (!Number.isInteger(entry) || !DEVICE.test(device || '')) return fail('bad request');
  const added = await env.DB.prepare('INSERT INTO reports (entry, device, created) VALUES (?, ?, ?) ON CONFLICT DO NOTHING RETURNING entry')
    .bind(entry, device, Date.now()).first();
  if (added) {
    await env.DB.prepare('UPDATE entries SET reports = reports + 1, hidden = (reports + 1 >= ?) WHERE id = ?')
      .bind(HIDE_AFTER_REPORTS, entry).run();
  }
  return json({ ok: true });
}
