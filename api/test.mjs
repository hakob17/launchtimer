// End-to-end test of the leaderboard API against a local Worker and D1:
//   npx wrangler d1 migrations apply launchtimer --local && node test.mjs
// test-runs.json holds real engine output (the demo drive), made by build/export-runs.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createHash, generateKeyPairSync, sign, randomUUID } from 'node:crypto';
import { encode } from 'cbor-x';

const PORT = 8799, BASE = `http://127.0.0.1:${PORT}`;
const dev = spawn('npx', ['wrangler', 'dev', '--local', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
let log = '';
dev.stdout.on('data', d => { log += d; });
dev.stderr.on('data', d => { log += d; });
const sleep = ms => new Promise(r => setTimeout(r, ms));
for (let i = 0; i < 100; i++) {
  try { if ((await fetch(BASE)).ok) break; } catch {}
  await sleep(300);
}

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);
  if (!ok) failures++;
};
const post = (path, body) => fetch(BASE + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(async r => ({ status: r.status, ...(await r.json()) }));
const get = path => fetch(BASE + path).then(r => r.json());

const [launch, braking] = JSON.parse(readFileSync(new URL('./test-runs.json', import.meta.url)));
const now = Date.now();
const fresh = run => ({ ...structuredClone(run), id: randomUUID(), date: now });
const payload = (device, run, car = { make: 'Tesla', model: 'Model 3', year: 2024, trim: 'Performance' }) =>
  ({ device, handle: 'Crimson Falcon 42', car, country: 'US', run });

try {
  const device = randomUUID().toUpperCase();

  // A real launch and a real stop are accepted and ranked.
  let r = await post('/v1/runs', { payload: JSON.stringify(payload(device, fresh(launch))) });
  check('launch accepted', r.ok, JSON.stringify(r.error || r.results?.map(x => `${x.metric}=${x.value} #${x.overall.rank}/${x.overall.of}`)));
  check('launch posts 0-60 with rollout', r.results?.some(x => x.metric === '0-60mph' && Math.abs(x.value - launch.results.find(y => y.id === '0-60mph').rollout) < 1e-6));
  check('unsigned posts are not verified', r.results?.every(x => x.verified === false));
  r = await post('/v1/runs', { payload: JSON.stringify(payload(device, fresh(braking))) });
  check('braking accepted', r.ok && r.results?.some(x => x.metric === '60-0mph'), JSON.stringify(r.error || r.results));

  // Edited times, impossible traces, demo runs and slopes are refused.
  const edited = fresh(launch);
  edited.results.find(x => x.id === '0-60mph').rollout -= 0.3;
  r = await post('/v1/runs', { payload: JSON.stringify(payload(device, edited)) });
  check('edited 0-60 refused', !r.ok, r.error);
  const rocket = fresh(launch);
  rocket.trace = rocket.trace.map(([t, v, a]) => [t, v * 2.2, a]);
  r = await post('/v1/runs', { payload: JSON.stringify(payload(device, rocket)) });
  check('impossible trace refused', !r.ok, r.error);
  r = await post('/v1/runs', { payload: JSON.stringify(payload(device, { ...fresh(launch), source: 'Demo' })) });
  check('demo run refused', !r.ok, r.error);
  r = await post('/v1/runs', { payload: JSON.stringify(payload(device, { ...fresh(launch), grade: -0.03 })) });
  check('downhill run refused', !r.ok, r.error);
  r = await post('/v1/runs', { payload: JSON.stringify({ ...payload(device, fresh(launch)), handle: 'Anything I Like' }) });
  check('typed handle refused', !r.ok, r.error);
  r = await post('/v1/runs', { payload: JSON.stringify(payload(device, fresh(launch), { make: 'Tesla', model: 'Model 3', year: 2024, trim: 'fuck' })) });
  check('abusive trim refused', !r.ok, r.error);

  // A second, slower driver ranks behind.
  const other = randomUUID().toUpperCase();
  const slower = fresh(launch);
  slower.trace = slower.trace.map(([t, v, a]) => [t, v * 0.8, a]);
  const vs = slower.trace.map(p => p[1]), ts = slower.trace.map(p => p[0]);
  const ds = [0]; for (let i = 1; i < ts.length; i++) ds.push(ds[i - 1] + (vs[i] + vs[i - 1]) / 2 * (ts[i] - ts[i - 1]));
  const at = (series, level) => { const i = series.findIndex(x => x >= level); return ts[i - 1] + (level - series[i - 1]) / (series[i] - series[i - 1]) * (ts[i] - ts[i - 1]); };
  slower.results = [{ id: '0-60mph', time: at(vs, 26.8224) - ts[0], rollout: at(vs, 26.8224) - at(ds, 0.3048) }];
  r = await post('/v1/runs', { payload: JSON.stringify(payload(other, slower, { make: 'Dodge', model: 'Durango', year: 2023, trim: 'SRT Hellcat' })) });
  check('slower driver accepted and ranked 2nd', r.ok && r.results?.[0].overall.rank === 2, JSON.stringify(r.error || r.results?.[0]));

  const board = await get('/v1/board?metric=0-60mph');
  check('board lists both, best first', board.entries?.length === 2 && board.entries[0].model === 'Model 3', JSON.stringify(board.entries?.map(e => [e.handle, e.model, e.value])));
  const byModel = await get('/v1/board?metric=0-60mph&make=Dodge&model=Durango');
  check('board filters by model', byModel.entries?.length === 1 && byModel.entries[0].model === 'Durango');
  const mine = await get(`/v1/me?metric=0-60mph&device=${device}`);
  check('me returns best and rank', mine.best && mine.overall.rank === 1, JSON.stringify(mine));

  // Three reports hide an entry.
  const target = board.entries[1].id;
  for (let i = 0; i < 3; i++) await post('/v1/report', { entry: target, device: randomUUID() });
  const after = await get('/v1/board?metric=0-60mph');
  check('reported entry hidden', after.entries?.length === 1, JSON.stringify(after.entries?.map(e => e.id)));

  // Garbage attestation is refused; challenges are single-use.
  const { challenge } = await get('/v1/challenge');
  r = await post('/v1/attest', { device, keyId: 'AAAA', attestation: btoa('nope'), challenge });
  check('garbage attestation refused', !r.ok, r.error);
  r = await post('/v1/attest', { device, keyId: 'AAAA', attestation: btoa('nope'), challenge });
  check('challenge single-use', r.error === 'challenge expired', r.error);

  // Assertions: sign a post with our own P-256 key registered as the device's key.
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const spki = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const signedDevice = randomUUID().toUpperCase();
  const sql = `INSERT INTO devices (id, key_id, public_key, counter, env, created) VALUES ('${signedDevice}', 'test', '${spki}', 0, 'development', 0)`;
  await new Promise((res, rej) => spawn('npx', ['wrangler', 'd1', 'execute', 'launchtimer', '--local', '--command', sql], { stdio: 'ignore' }).on('exit', c => c ? rej(c) : res()));
  const signPost = (body, counter) => {
    const rpIdHash = createHash('sha256').update('SXEFA57E5G.com.hakobhakobyan.launchtimer').digest();
    const authData = Buffer.concat([rpIdHash, Buffer.from([0x40]), Buffer.from([0, 0, 0, counter])]);
    const clientDataHash = createHash('sha256').update(body).digest();
    const signature = sign('sha256', Buffer.concat([authData, clientDataHash]), privateKey);
    return Buffer.from(encode({ signature, authenticatorData: authData })).toString('base64');
  };
  const body = JSON.stringify(payload(signedDevice, fresh(launch)));
  r = await post('/v1/runs', { payload: body, assertion: signPost(body, 1) });
  check('signed post verified', r.ok && r.results?.every(x => x.verified), JSON.stringify(r.error || r.results?.[0]));
  const body2 = JSON.stringify(payload(signedDevice, fresh(launch)));
  r = await post('/v1/runs', { payload: body2, assertion: signPost(body2, 1) });
  check('replayed counter refused', !r.ok, r.error);
  r = await post('/v1/runs', { payload: body2, assertion: signPost(body, 2) });
  check('signature over other payload refused', !r.ok, r.error);
} finally {
  dev.kill();
}
if (failures) console.log(log.slice(-3000));
console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures ? 1 : 0);
