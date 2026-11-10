import { afterEach, describe, expect, it, vi } from 'vitest';
import { verifyAccessJwt } from '../src/worker/auth';
import { b64url } from '../src/worker/util';

const TEAM = 'lifenz.cloudflareaccess.com';
const AUD = 'aud-123';

let n = 0;
async function setup() {
  const kid = `k${++n}`;
  const kp = (await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  const jwk = { ...(await crypto.subtle.exportKey('jwk', kp.publicKey)), kid };
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }))));
  const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  return async (claims: Record<string, unknown>) => {
    const head = enc({ alg: 'RS256', kid });
    const body = enc(claims);
    const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', kp.privateKey, new TextEncoder().encode(`${head}.${body}`));
    return `${head}.${body}.${b64url(new Uint8Array(sig))}`;
  };
}

const good = () => ({ aud: [AUD], email: 'pa@lifenz.org', exp: Date.now() / 1000 + 600, iss: `https://${TEAM}` });

describe('Cloudflare Access JWT', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('accepts a valid token and returns the email', async () => {
    const sign = await setup();
    expect(await verifyAccessJwt(await sign(good()), TEAM, AUD)).toBe('pa@lifenz.org');
  });
  it('rejects wrong audience, expiry, issuer and tampering', async () => {
    const sign = await setup();
    await expect(verifyAccessJwt(await sign({ ...good(), aud: ['other'] }), TEAM, AUD)).rejects.toThrow(/audience/);
    await expect(verifyAccessJwt(await sign({ ...good(), exp: 1 }), TEAM, AUD)).rejects.toThrow(/expired/);
    await expect(verifyAccessJwt(await sign({ ...good(), iss: 'https://evil.example' }), TEAM, AUD)).rejects.toThrow(/issuer/);
    const t = (await sign(good())).split('.');
    const forged = `${t[0]}.${b64url(new TextEncoder().encode(JSON.stringify({ ...good(), email: 'admin@lifenz.org' })))}.${t[2]}`;
    await expect(verifyAccessJwt(forged, TEAM, AUD)).rejects.toThrow(/signature/);
  });
});
