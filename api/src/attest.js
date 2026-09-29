// Apple App Attest: proves a leaderboard post came from the genuine Launch Timer app on a real
// iPhone, not a script. https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
//
// Once per install the app creates a key in the Secure Enclave and Apple certifies it (an
// "attestation"); we check that certificate chain and keep the public key. Every post is then
// signed with that key (an "assertion") and carries a counter that must only go up.

import { decode } from 'cbor-x';
import * as x509 from '@peculiar/x509';
import APPLE_ROOT from './apple-root.js';

x509.cryptoProvider.set(crypto);

export const APP_ID = 'SXEFA57E5G.com.hakobhakobyan.launchtimer';
const NONCE_OID = '1.2.840.113635.100.8.2';
const enc = new TextEncoder();

export const fromB64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
export const toB64 = bytes => btoa(String.fromCharCode(...bytes));
export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}
const concat = (a, b) => { const out = new Uint8Array(a.length + b.length); out.set(a); out.set(b, a.length); return out; };
const equal = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const u32 = (b, i) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];

/**
 * Checks an attestation object for the key `keyId` made against `challenge`.
 * Returns the key (SPKI, base64) and the environment ("development" or "production").
 */
// The app passes SHA256(challenge) to attestKey as the client-data hash (Sources/Leaderboard.swift);
// tests with Apple's sample pass its client-data hash directly.
export async function verifyAttestation({ keyId, attestation, challenge, clientDataHash, appId = APP_ID, date = new Date() }) {
  const att = decode(fromB64(attestation));
  if (att.fmt !== 'apple-appattest') throw new Error('not an App Attest object');
  const authData = new Uint8Array(att.authData);
  const [credDer, interDer] = att.attStmt.x5c.map(c => new Uint8Array(c));

  // 1. The certificate chain leads to Apple's App Attestation root.
  const root = new x509.X509Certificate(APPLE_ROOT);
  const inter = new x509.X509Certificate(interDer);
  const cred = new x509.X509Certificate(credDer);
  if (!(await inter.verify({ publicKey: root.publicKey, date }))) throw new Error('bad intermediate');
  if (!(await cred.verify({ publicKey: inter.publicKey, date }))) throw new Error('bad credential certificate');

  // 2. The certificate embeds a nonce made from authData and our challenge.
  const hash = clientDataHash ?? await sha256(enc.encode(challenge));
  const nonce = await sha256(concat(authData, hash));
  const ext = cred.getExtension(NONCE_OID);
  if (!ext) throw new Error('no nonce extension');
  const extValue = new Uint8Array(ext.value);
  if (!equal(extValue.slice(-32), nonce)) throw new Error('nonce mismatch');

  // 3. The key id is the hash of the certified public key.
  const spki = new Uint8Array(cred.publicKey.rawData);
  const point = spki.slice(-65);
  const keyIdBytes = fromB64(keyId);
  if (!equal(await sha256(point), keyIdBytes)) throw new Error('key id mismatch');

  // 4. authData: rpIdHash(32) flags(1) counter(4) aaguid(16) credIdLen(2) credId.
  if (!equal(authData.slice(0, 32), await sha256(enc.encode(appId)))) throw new Error('wrong app');
  if (u32(authData, 33) !== 0) throw new Error('counter not zero');
  const aaguid = new TextDecoder().decode(authData.slice(37, 53));
  const env = aaguid === 'appattestdevelop' ? 'development'
    : aaguid === 'appattest\0\0\0\0\0\0\0' ? 'production' : null;
  if (!env) throw new Error('unknown aaguid');
  const credIdLength = (authData[53] << 8) + authData[54];
  if (!equal(authData.slice(55, 55 + credIdLength), keyIdBytes)) throw new Error('credential id mismatch');

  return { publicKey: toB64(spki), env };
}

/**
 * Checks that `assertion` signs `clientData` with the stored key and that its counter moved on.
 * Returns the new counter.
 */
export async function verifyAssertion({ publicKey, counter, assertion, clientData }) {
  const a = decode(fromB64(assertion));
  const authData = new Uint8Array(a.authenticatorData);
  const signature = derToRaw(new Uint8Array(a.signature));
  if (!equal(authData.slice(0, 32), await sha256(enc.encode(APP_ID)))) throw new Error('wrong app');
  const next = u32(authData, 33);
  if (next <= counter) throw new Error('replayed assertion');

  const key = await crypto.subtle.importKey('spki', fromB64(publicKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  const signed = concat(authData, await sha256(clientData));
  // The key signs nonce = SHA256(authData ‖ SHA256(clientData)). Implementations disagree on
  // whether that nonce is hashed once more before signing, so accept either form.
  const ecdsa = { name: 'ECDSA', hash: 'SHA-256' };
  const ok = await crypto.subtle.verify(ecdsa, key, signature, signed)
    || await crypto.subtle.verify(ecdsa, key, signature, await sha256(signed));
  if (!ok) throw new Error('bad signature');
  return next;
}

/** ECDSA signatures arrive DER-encoded; WebCrypto wants r ‖ s, 32 bytes each. */
function derToRaw(der) {
  let i = 2;
  if (der[1] & 0x80) i += der[1] & 0x7f;
  const read = () => {
    if (der[i++] !== 0x02) throw new Error('bad signature encoding');
    const len = der[i++];
    let n = der.slice(i, i + len);
    i += len;
    while (n.length > 32 && n[0] === 0) n = n.slice(1);
    const out = new Uint8Array(32);
    out.set(n, 32 - n.length);
    return out;
  };
  return concat(read(), read());
}
