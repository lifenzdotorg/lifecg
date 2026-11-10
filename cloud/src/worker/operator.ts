import type { Role } from './env';

/** Roles that may run a CG Mac's control GUI with their LIFE sign-in. */
export const CONTROL_ROLES: Role[] = ['operator', 'production', 'admin'];
export const ROLES: Role[] = ['pa', 'operator', 'production', 'admin'];

export const CODE_TTL_MS = 2 * 60_000;

/**
 * The sign-in link only ever sends a code back to a CG Mac's control GUI on the local network:
 * `http(s)://<private IPv4 | localhost | *.local>[:port]/control`. Anything else is refused, so the
 * link can't be used to hand a code to another site.
 */
export function controlReturnUrl(raw: string | undefined): URL | null {
  if (!raw) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  if (u.pathname !== '/control' && u.pathname !== '/control/') return null;
  const h = u.hostname.toLowerCase();
  const ip = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  let ok = false;
  if (ip) {
    const [a, b] = [Number(ip[1]), Number(ip[2])];
    if ([1, 2, 3, 4].every((i) => Number(ip[i]) <= 255)) {
      ok = a === 10 || a === 127 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31);
    }
  } else {
    ok = h === 'localhost' || /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.local$/.test(h);
  }
  if (!ok) return null;
  u.search = '';
  u.hash = '';
  return u;
}

export const page = (title: string, body: string) =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">` +
  `<title>${title}</title><style>body{font:16px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;` +
  `background:#111316;color:#eef0f3;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;padding:24px}` +
  `main{max-width:440px}h1{font-size:22px}p{color:#b8bec7}a{color:#4da3ff}</style></head><body><main>${body}</main></body></html>`;

export const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
