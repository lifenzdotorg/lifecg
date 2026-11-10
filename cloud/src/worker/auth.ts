import type { MiddlewareHandler } from 'hono';
import type { AppEnv, Bindings, Role, User } from './env';
import { b64urlDecode, now, sha256Hex } from './util';

// ---- Cloudflare Access JWT ----

interface Jwk extends JsonWebKey {
  kid: string;
}
let certCache: { domain: string; at: number; keys: Jwk[] } | null = null;

async function accessKeys(domain: string, force = false): Promise<Jwk[]> {
  if (!force && certCache && certCache.domain === domain && Date.now() - certCache.at < 3600_000) return certCache.keys;
  const res = await fetch(`https://${domain}/cdn-cgi/access/certs`);
  if (!res.ok) throw new Error(`Access certs: HTTP ${res.status}`);
  const body = (await res.json()) as { keys: Jwk[] };
  certCache = { domain, at: Date.now(), keys: body.keys };
  return body.keys;
}

/** Verifies a `Cf-Access-Jwt-Assertion` (RS256) against the team's certs; returns the email claim. */
export async function verifyAccessJwt(token: string, teamDomain: string, aud: string): Promise<string> {
  const domain = teamDomain.replace(/^https?:\/\//, '').replace(/\/+$/, '');
  const [h, p, s] = token.split('.');
  if (!h || !p || !s) throw new Error('malformed JWT');
  const header = JSON.parse(new TextDecoder().decode(b64urlDecode(h))) as { alg: string; kid: string };
  if (header.alg !== 'RS256') throw new Error('unexpected JWT alg');
  let jwk = (await accessKeys(domain)).find((k) => k.kid === header.kid);
  if (!jwk) jwk = (await accessKeys(domain, true)).find((k) => k.kid === header.kid); // key rotation
  if (!jwk) throw new Error('unknown JWT key');
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlDecode(s), new TextEncoder().encode(`${h}.${p}`));
  if (!ok) throw new Error('bad JWT signature');
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(p))) as { aud: string | string[]; exp: number; nbf?: number; iss: string; email?: string };
  const t = Date.now() / 1000;
  const auds = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!auds.includes(aud)) throw new Error('JWT audience mismatch');
  if (claims.exp < t || (claims.nbf && claims.nbf > t + 60)) throw new Error('JWT expired');
  if (claims.iss !== `https://${domain}`) throw new Error('JWT issuer mismatch');
  if (!claims.email) throw new Error('JWT has no email');
  return claims.email;
}

async function authenticatedEmail(req: Request, env: Bindings): Promise<string | null> {
  if (env.ACCESS_TEAM_DOMAIN && env.ACCESS_AUD) {
    const jwt = req.headers.get('Cf-Access-Jwt-Assertion');
    if (!jwt) return null;
    const email = await verifyAccessJwt(jwt, env.ACCESS_TEAM_DOMAIN, env.ACCESS_AUD);
    const header = req.headers.get('Cf-Access-Authenticated-User-Email');
    if (header && header.toLowerCase() !== email.toLowerCase()) throw new Error('Access email header mismatch');
    return email;
  }
  // Production (team domain configured) must verify the JWT: fail closed until ACCESS_AUD is set.
  if (env.ACCESS_TEAM_DOMAIN) throw new Error('ACCESS_AUD is not configured');
  if (env.DEV_USER_EMAIL) return env.DEV_USER_EMAIL;
  // Local dev without DEV_USER_EMAIL: trust the header.
  return req.headers.get('Cf-Access-Authenticated-User-Email');
}

const adminList = (env: Bindings) =>
  (env.ADMIN_EMAILS ?? '').split(/[,\s]+/).map((e) => e.trim().toLowerCase()).filter(Boolean);

/** Portal auth: Access identity -> users row (created as `pa` for @lifenz.org, admin if in ADMIN_EMAILS). */
export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  let email: string | null;
  try {
    email = await authenticatedEmail(c.req.raw, c.env);
  } catch (e) {
    console.warn('auth failed', (e as Error).message);
    return c.json({ error: 'Not signed in' }, 401);
  }
  if (!email) return c.json({ error: 'Not signed in' }, 401);
  email = email.trim().toLowerCase();
  const db = c.env.DB;
  let user = await db.prepare('SELECT email, name, role FROM users WHERE email = ?').bind(email).first<User>();
  const isAdmin = adminList(c.env).includes(email);
  if (!user) {
    if (!isAdmin && !email.endsWith('@lifenz.org')) return c.json({ error: `${email} has no access to the notes portal` }, 403);
    user = { email, name: null, role: isAdmin ? 'admin' : 'pa' };
    await db.prepare('INSERT INTO users (email, role, created_at, last_seen) VALUES (?, ?, ?, ?)').bind(email, user.role, now(), now()).run();
  } else {
    if (isAdmin && user.role !== 'admin') user.role = 'admin';
    await db.prepare('UPDATE users SET last_seen = ?, role = ? WHERE email = ?').bind(now(), user.role, email).run();
  }
  c.set('user', user);
  await next();
};

export const requireRole =
  (...roles: Role[]): MiddlewareHandler<AppEnv> =>
  async (c, next) => {
    if (!roles.includes(c.get('user').role)) return c.json({ error: 'Not allowed' }, 403);
    await next();
  };

export const canSeeAll = (u: User) => u.role === 'production' || u.role === 'admin';

/** Device API: `Authorization: Bearer <token>`; tokens are stored as SHA-256 hashes. */
export const requireDevice: MiddlewareHandler<AppEnv> = async (c, next) => {
  const m = /^Bearer\s+(\S+)$/i.exec(c.req.header('Authorization') ?? '');
  if (!m) return c.json({ error: 'Missing device token' }, 401);
  const hash = await sha256Hex(m[1]);
  const device = await c.env.DB.prepare('SELECT id, name, campus_id FROM devices WHERE token_hash = ?')
    .bind(hash)
    .first<{ id: string; name: string; campus_id: string }>();
  if (!device) return c.json({ error: 'Unknown device token' }, 401);
  c.set('device', device);
  await c.env.DB.prepare('UPDATE devices SET last_seen = ? WHERE id = ?').bind(now(), device.id).run();
  await next();
};
