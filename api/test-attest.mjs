// Checks verifyAttestation against Apple's published sample attestation object
// (developer.apple.com/documentation/devicecheck/attestation-object-validation-guide).
import { readFileSync } from 'node:fs';
import { verifyAttestation } from './src/attest.js';

const attestation = readFileSync(new URL('./test-apple-attestation.b64', import.meta.url), 'utf8').replace(/\s/g, '');
const base = { keyId: 'bSrEhF8TIzIvWSPwvZ0i2+UOBre4ASH84rK15m6emNY=', attestation, clientDataHash: new TextEncoder().encode('test_server_challenge'),
  appId: '0352187391.com.apple.example_app_attest', date: new Date('2024-04-18T12:00:00Z') };
let failures = 0;
const expect = async (name, params, wantError) => {
  try {
    const r = await verifyAttestation({ ...base, ...params });
    const ok = !wantError && r.env === 'production' && r.publicKey.length > 80;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name} → ${r.env}`); if (!ok) failures++;
  } catch (e) {
    const ok = !!wantError && e.message.includes(wantError);
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name} → ${e.message}`); if (!ok) failures++;
  }
};
await expect('Apple sample verifies', {});
await expect('wrong challenge refused', { clientDataHash: new TextEncoder().encode('other') }, 'nonce');
await expect('wrong app refused', { appId: '0352187391.com.apple.other' }, 'wrong app');
await expect('expired certificate refused', { date: new Date('2026-09-29') }, 'bad');
await expect('wrong key id refused', { keyId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' }, 'key id');
console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures ? 1 : 0);
