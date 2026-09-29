// Checks a posted run against its own speed trace and against physics, so a leaderboard time
// has to be backed by a plausible drive and can't just be typed in.

const MPH = 0.44704, KMH = 1 / 3.6, FOOT = 0.3048;

// Every board, how its value is read from the app's run, and the quickest believable value.
// Launch boards follow their home convention: US times with 1-ft rollout, metric without.
export const METRICS = {
  '0-60mph': { label: '0–60 mph', unit: 's', from: 0, to: 60 * MPH, rollout: true, floor: 1.75 },
  '0-100kmh': { label: '0–100 km/h', unit: 's', from: 0, to: 100 * KMH, rollout: false, floor: 1.8 },
  quarter: { label: '¼ mile', unit: 's', distance: 402.336, rollout: true, floor: 7.8 },
  '60-130mph': { label: '60–130 mph', unit: 's', from: 60 * MPH, to: 130 * MPH, floor: 2.6 },
  '100-200kmh': { label: '100–200 km/h', unit: 's', from: 100 * KMH, to: 200 * KMH, floor: 3.6 },
  '60-0mph': { label: '60–0 mph', unit: 'm', braking: 60 * MPH, floor: 24 },
};

/** Returns { entries: [{metric, value}], grade } or throws with a reason. */
export function validateRun(run) {
  if (!run || typeof run !== 'object') throw new Error('no run');
  if (run.source !== 'iPhone') throw new Error('only runs measured by the phone count');
  if (!['launch', 'rolling', 'braking'].includes(run.kind)) throw new Error('unknown run kind');
  const age = Date.now() - Number(run.date);
  if (!(age > -60_000 && age < 7 * 86_400_000)) throw new Error('run too old');
  if (run.grade != null && Math.abs(run.grade) > 0.01) throw new Error('slope over 1%');

  const trace = run.trace;
  if (!Array.isArray(trace) || trace.length < 20 || trace.length > 4000) throw new Error('bad trace');
  const t = [], v = [];
  for (const p of trace) {
    if (!Array.isArray(p) || p.length < 2 || !p.slice(0, 2).every(Number.isFinite)) throw new Error('bad trace point');
    if (t.length && p[0] <= t[t.length - 1]) throw new Error('trace not in time order');
    if (p[1] < -0.5 || p[1] > 140) throw new Error('impossible speed');
    t.push(p[0]); v.push(p[1]);
  }
  if (t[t.length - 1] - t[0] > 120) throw new Error('trace too long');
  // No real car pulls or stops harder than about 1.7 g for half a second at a time.
  for (let i = 0, j = 0; i < t.length; i++) {
    while (t[i] - t[j] > 0.5) j++;
    if (t[i] - t[j] >= 0.4 && Math.abs(v[i] - v[j]) / (t[i] - t[j]) > 1.7 * 9.80665) throw new Error('impossible acceleration');
  }

  const d = [0];
  for (let i = 1; i < t.length; i++) d.push(d[i - 1] + (v[i] + v[i - 1]) / 2 * (t[i] - t[i - 1]));
  const rising = (series, level) => {
    const i = series.findIndex(x => x >= level);
    if (i < 0) return null;
    if (i === 0) return t[0];
    return t[i - 1] + (level - series[i - 1]) / (series[i] - series[i - 1] || 1e-9) * (t[i] - t[i - 1]);
  };
  const rolloutAt = rising(d, FOOT);
  const claimed = id => (run.results || []).find(r => r.id === id);

  const entries = [];
  for (const [id, m] of Object.entries(METRICS)) {
    const r = claimed(id);
    if (!r) continue;
    let value, computed;
    if (m.braking != null) {
      if (run.kind !== 'braking' || !Number.isFinite(r.distance)) continue;
      const i = v.findLastIndex(x => x >= m.braking);
      if (i < 0 || i + 1 >= v.length || v[v.length - 1] > 1) continue;
      const f = (v[i] - m.braking) / (v[i] - v[i + 1] || 1e-9);
      const tc = t[i] + f * (t[i + 1] - t[i]);
      computed = d[d.length - 1] - (d[i] + (m.braking + v[i]) / 2 * (tc - t[i]));
      if (Math.abs(computed - r.distance) > 1.5) throw new Error(`${id} doesn't match the trace`);
      value = r.distance;
    } else if (m.distance != null || m.from === 0) {
      if (run.kind !== 'launch') continue;
      const tc = m.distance != null ? rising(d, m.distance) : rising(v, m.to);
      if (tc == null) continue;
      if (m.rollout && rolloutAt == null) continue;
      computed = tc - (m.rollout ? rolloutAt : t[0]);
      value = m.rollout ? r.rollout : r.time;
      if (!Number.isFinite(value) || Math.abs(computed - value) > 0.08) throw new Error(`${id} doesn't match the trace`);
    } else {
      if (!(v[0] < m.from - 1)) continue;
      const a = rising(v, m.from), b = rising(v, m.to);
      if (a == null || b == null) continue;
      computed = b - a;
      value = r.time;
      if (!Number.isFinite(value) || Math.abs(computed - value) > 0.08) throw new Error(`${id} doesn't match the trace`);
    }
    if (value < m.floor) throw new Error(`${id} is quicker than any production car`);
    entries.push({ metric: id, value: Math.round(value * 1000) / 1000 });
  }
  if (!entries.length) throw new Error('nothing to post');
  return { entries, grade: run.grade ?? null };
}
