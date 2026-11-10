import { Hono } from 'hono';
import { THEME_IDS } from '../../shared/themes';
import { zonedToIso } from '../../shared/time';
import type { Slide } from '../../shared/types';
import { canSeeAll, requireDevice, requireRole, requireUser } from './auth';
import { sendNotesEmail } from './email';
import type { AppEnv, User } from './env';
import { CODE_TTL_MS, CONTROL_ROLES, ROLES, controlReturnUrl, esc, page } from './operator';
import { listServices, servicePackage, summary } from './services';
import { b64url, isEmail, newId, now, sha256Hex } from './util';

const app = new Hono<AppEnv>();

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: err.message || 'Server error' }, 500);
});

// ───────────────────────── Device API (token auth, not behind Access) ─────────────────────────

const device = new Hono<AppEnv>();
device.use('*', requireDevice);

device.get('/services', async (c) => {
  const d = c.get('device');
  const all = c.req.query('campus') === 'all';
  const rows = await listServices(c.env.DB, {
    fromUtc: new Date(Date.now() - 12 * 3600_000).toISOString(),
    campusId: all ? undefined : d.campus_id,
  });
  return c.json({ device: { id: d.id, name: d.name, campusId: d.campus_id }, services: rows.map(summary) });
});

device.get('/services/:id', async (c) => {
  const pkg = await servicePackage(c.env.DB, c.req.param('id'));
  return pkg ? c.json(pkg) : c.json({ error: 'No such service' }, 404);
});

device.post('/heartbeat', async (c) => {
  const b = await c.req.json<{ appVersion?: string; loadedServiceId?: string | null; loadedVersion?: number | null }>().catch(() => ({}) as never);
  await c.env.DB.prepare('UPDATE devices SET last_seen = ?, app_version = ?, loaded_service_id = ?, loaded_version = ? WHERE id = ?')
    .bind(now(), b.appVersion ?? null, b.loadedServiceId ?? null, typeof b.loadedVersion === 'number' ? b.loadedVersion : null, c.get('device').id)
    .run();
  return c.json({ ok: true });
});

/** Redeem a one-time operator sign-in code (from the redirect to the Mac's control GUI). Single use, 2 minutes. */
device.post('/operator/redeem', async (c) => {
  const b = await c.req.json<{ code?: string }>().catch(() => ({}) as { code?: string });
  if (typeof b.code !== 'string' || b.code.length < 20) return c.json({ error: 'Invalid code' }, 400);
  const hash = await sha256Hex(b.code);
  const t = now();
  // Mark used atomically so a code can't be redeemed twice.
  const row = await c.env.DB.prepare(
    'UPDATE operator_codes SET used_at = ?, used_by = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ? RETURNING email',
  )
    .bind(t, c.get('device').id, hash, t)
    .first<{ email: string }>();
  if (!row) return c.json({ error: 'This sign-in link has expired or was already used. Sign in again.' }, 401);
  const user = await c.env.DB.prepare('SELECT email, name, role FROM users WHERE email = ?').bind(row.email).first<User>();
  if (!user || !CONTROL_ROLES.includes(user.role)) return c.json({ error: `${row.email} is not allowed to run the CG Macs` }, 403);
  return c.json({ email: user.email, name: user.name, role: user.role });
});

/** Is this person still allowed to run the CG Macs? (The Mac re-checks remembered sign-ins.) */
device.post('/operator/check', async (c) => {
  const b = await c.req.json<{ email?: string }>().catch(() => ({}) as { email?: string });
  const email = (b.email ?? '').trim().toLowerCase();
  const user = await c.env.DB.prepare('SELECT email, name, role FROM users WHERE email = ?').bind(email).first<User>();
  return c.json({ allowed: !!user && CONTROL_ROLES.includes(user.role), role: user?.role ?? null, name: user?.name ?? null });
});

app.route('/api/device', device);

// ───────────────────────── Operator sign-in for a Mac's control GUI (Access) ─────────────────────────

/**
 * The control GUI on a CG Mac links here (`?return=http://<mac>:<port>/control`). Access has already
 * signed the person in; operators/production/admins are sent back with a one-time code in the URL
 * fragment (never sent to a server log), which the Mac redeems through the device API.
 */
app.get('/operator/signin', requireUser, async (c) => {
  const user = c.get('user');
  const ret = controlReturnUrl(c.req.query('return'));
  if (!ret) {
    return c.html(page('Sign-in link not valid', '<h1>That sign-in link isn\'t valid</h1><p>Open the control page on the CG Mac (on the church network) and tap <b>Sign in with LIFE account</b> again.</p>'), 400);
  }
  if (!CONTROL_ROLES.includes(user.role)) {
    return c.html(
      page(
        'Not an operator',
        `<h1>You can't run the CG Macs yet</h1><p>You're signed in as <b>${esc(user.email)}</b> (${user.role === 'pa' ? 'PA' : esc(user.role)}). ` +
          `Ask a portal admin to make you an <b>Operator</b>, or use the PIN shown on the Mac.</p><p><a href="${esc(ret.toString())}">Back to the control page</a></p>`,
      ),
      403,
    );
  }
  const code = b64url(crypto.getRandomValues(new Uint8Array(24)));
  const t = Date.now();
  await c.env.DB.batch([
    c.env.DB.prepare('DELETE FROM operator_codes WHERE expires_at < ?').bind(new Date(t - 86400_000).toISOString()),
    c.env.DB.prepare('INSERT INTO operator_codes (code_hash, email, created_at, expires_at) VALUES (?, ?, ?, ?)').bind(
      await sha256Hex(code),
      user.email,
      new Date(t).toISOString(),
      new Date(t + CODE_TTL_MS).toISOString(),
    ),
  ]);
  ret.hash = `code=${code}`;
  c.header('Cache-Control', 'no-store');
  c.header('Referrer-Policy', 'no-referrer');
  return c.redirect(ret.toString(), 302);
});

// ───────────────────────── Fonts (signed-in users only) ─────────────────────────

app.get('/fonts/:file', requireUser, async (c) => {
  const m = /^([A-Za-z0-9-]+)\.ttf$/.exec(c.req.param('file'));
  if (!m) return c.text('Not found', 404);
  const obj = await c.env.PRIVATE.get(`fonts/${m[1]}.ttf`);
  if (!obj) return c.text(`Font ${m[1]} is not in the PRIVATE bucket (see cloud/README.md)`, 404);
  return new Response(obj.body, { headers: { 'Content-Type': 'font/ttf', 'Cache-Control': 'private, max-age=86400' } });
});

// ───────────────────────── Portal API (Access) ─────────────────────────

const api = new Hono<AppEnv>();
api.use('*', requireUser);

api.get('/me', (c) => c.json({ user: c.get('user'), themes: THEME_IDS }));

// Campuses + recipients
api.get('/campuses', async (c) => {
  const db = c.env.DB;
  const { results: campuses } = await db.prepare('SELECT id, name, default_theme_id, sort, send_probundle FROM campuses ORDER BY sort').all();
  const { results: recips } = await db.prepare('SELECT campus_id, email, name FROM campus_recipients ORDER BY email').all<{ campus_id: string; email: string; name: string | null }>();
  return c.json({
    campuses: campuses.map((x) => ({ ...x, recipients: recips.filter((r) => r.campus_id === (x as { id: string }).id) })),
  });
});

api.patch('/campuses/:id', requireRole('admin'), async (c) => {
  const b = await c.req.json<{ default_theme_id?: string; name?: string; send_probundle?: boolean }>();
  if (b.default_theme_id && !THEME_IDS.includes(b.default_theme_id)) return c.json({ error: 'Unknown theme' }, 400);
  await c.env.DB.prepare(
    'UPDATE campuses SET default_theme_id = COALESCE(?, default_theme_id), name = COALESCE(?, name), send_probundle = COALESCE(?, send_probundle) WHERE id = ?',
  )
    .bind(b.default_theme_id ?? null, b.name?.trim() || null, typeof b.send_probundle === 'boolean' ? (b.send_probundle ? 1 : 0) : null, c.req.param('id'))
    .run();
  return c.json({ ok: true });
});

api.post('/campuses/:id/recipients', requireRole('admin'), async (c) => {
  const b = await c.req.json<{ email: string; name?: string }>();
  const email = b.email?.trim().toLowerCase();
  if (!isEmail(email)) return c.json({ error: 'Invalid email' }, 400);
  await c.env.DB.prepare('INSERT OR REPLACE INTO campus_recipients (campus_id, email, name) VALUES (?, ?, ?)')
    .bind(c.req.param('id'), email, b.name?.trim() || null)
    .run();
  return c.json({ ok: true });
});

api.delete('/campuses/:id/recipients/:email', requireRole('admin'), async (c) => {
  await c.env.DB.prepare('DELETE FROM campus_recipients WHERE campus_id = ? AND email = ?').bind(c.req.param('id'), c.req.param('email').toLowerCase()).run();
  return c.json({ ok: true });
});

// Users
api.get('/users', requireRole('admin'), async (c) => {
  const { results } = await c.env.DB.prepare('SELECT email, name, role, created_at, last_seen FROM users ORDER BY email').all();
  return c.json({ users: results });
});

api.post('/users', requireRole('admin'), async (c) => {
  const b = await c.req.json<{ email: string; role?: string }>();
  const email = b.email?.trim().toLowerCase();
  const role = b.role ?? 'pa';
  if (!isEmail(email) || !(ROLES as string[]).includes(role)) return c.json({ error: 'Invalid user' }, 400);
  await c.env.DB.prepare('INSERT INTO users (email, role, created_at) VALUES (?, ?, ?) ON CONFLICT(email) DO UPDATE SET role = excluded.role')
    .bind(email, role, now())
    .run();
  return c.json({ ok: true });
});

api.patch('/users/:email', requireRole('admin'), async (c) => {
  const b = await c.req.json<{ role: string }>();
  if (!(ROLES as string[]).includes(b.role)) return c.json({ error: 'Invalid role' }, 400);
  await c.env.DB.prepare('UPDATE users SET role = ? WHERE email = ?').bind(b.role, c.req.param('email').toLowerCase()).run();
  return c.json({ ok: true });
});

// Messages
interface MessageRow {
  id: string;
  title: string;
  speaker: string;
  speaker_email: string | null;
  created_by: string;
  created_at: string;
  updated_at: string;
  source_text: string;
  blocks_json: string;
  slides_json: string;
  notes_key: string | null;
  notes_name: string | null;
  notes_type: string | null;
  notes_size: number | null;
}

const messageOut = (m: MessageRow) => ({
  id: m.id,
  title: m.title,
  speaker: m.speaker,
  speakerEmail: m.speaker_email,
  createdBy: m.created_by,
  createdAt: m.created_at,
  updatedAt: m.updated_at,
  sourceText: m.source_text,
  blocks: JSON.parse(m.blocks_json),
  slides: JSON.parse(m.slides_json),
  notesFile: m.notes_key ? { name: m.notes_name, type: m.notes_type, size: m.notes_size } : null,
});

async function loadMessage(c: { env: AppEnv['Bindings'] }, user: User, id: string) {
  const m = await c.env.DB.prepare('SELECT * FROM messages WHERE id = ?').bind(id).first<MessageRow>();
  if (!m) return { error: 'No such message', status: 404 as const };
  if (!canSeeAll(user) && m.created_by !== user.email) return { error: 'Not your message', status: 403 as const };
  return { m };
}

api.get('/messages', async (c) => {
  const user = c.get('user');
  const q = (c.req.query('q') ?? '').trim();
  const scope = canSeeAll(user) && c.req.query('scope') === 'all' ? 'all' : 'mine';
  const where: string[] = [];
  const args: unknown[] = [];
  if (scope === 'mine') where.push('m.created_by = ?'), args.push(user.email);
  if (q) {
    where.push('(m.title LIKE ?1x OR m.speaker LIKE ?1x OR m.source_text LIKE ?1x)'.replace(/\?1x/g, '?'));
    const like = `%${q.replace(/[%_]/g, '')}%`;
    args.push(like, like, like);
  }
  const { results } = await c.env.DB.prepare(
    `SELECT m.id, m.title, m.speaker, m.created_by, m.updated_at, json_array_length(m.slides_json) AS slide_count,
            (SELECT COUNT(DISTINCT service_id) FROM service_notes n WHERE n.message_id = m.id) AS push_count
       FROM messages m ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
      ORDER BY m.updated_at DESC LIMIT 200`,
  )
    .bind(...args)
    .all();
  return c.json({ scope, messages: results });
});

api.post('/messages', async (c) => {
  const user = c.get('user');
  const b = await c.req.json<{ title?: string; speaker?: string; speakerEmail?: string }>().catch(() => ({}) as never);
  const id = newId('msg');
  const t = now();
  await c.env.DB.prepare(
    'INSERT INTO messages (id, title, speaker, speaker_email, created_by, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
  )
    .bind(id, b.title ?? '', b.speaker ?? '', b.speakerEmail || null, user.email, t, t)
    .run();
  const m = await c.env.DB.prepare('SELECT * FROM messages WHERE id = ?').bind(id).first<MessageRow>();
  return c.json({ message: messageOut(m!) }, 201);
});

api.get('/messages/:id', async (c) => {
  const r = await loadMessage(c, c.get('user'), c.req.param('id'));
  if ('error' in r) return c.json({ error: r.error }, r.status);
  const pushes = await listServices(c.env.DB, { messageId: r.m.id, desc: true });
  return c.json({ message: messageOut(r.m), services: pushes.map((p) => ({ ...summary(p), messageId: p.message_id })) });
});

api.put('/messages/:id', async (c) => {
  const user = c.get('user');
  const r = await loadMessage(c, user, c.req.param('id'));
  if ('error' in r) return c.json({ error: r.error }, r.status);
  const b = await c.req.json<{ title: string; speaker: string; speakerEmail?: string | null; sourceText: string; blocks: unknown[]; slides: Slide[] }>();
  if (b.speakerEmail && !isEmail(b.speakerEmail)) return c.json({ error: 'Speaker email is not valid' }, 400);
  if (!Array.isArray(b.slides) || !Array.isArray(b.blocks)) return c.json({ error: 'blocks and slides required' }, 400);
  await c.env.DB.prepare(
    'UPDATE messages SET title = ?, speaker = ?, speaker_email = ?, source_text = ?, blocks_json = ?, slides_json = ?, updated_at = ? WHERE id = ?',
  )
    .bind(b.title ?? '', b.speaker ?? '', b.speakerEmail || null, b.sourceText ?? '', JSON.stringify(b.blocks), JSON.stringify(cleanSlides(b.slides)), now(), r.m.id)
    .run();
  return c.json({ ok: true, updatedAt: now() });
});

api.delete('/messages/:id', async (c) => {
  const r = await loadMessage(c, c.get('user'), c.req.param('id'));
  if ('error' in r) return c.json({ error: r.error }, r.status);
  const used = await c.env.DB.prepare('SELECT 1 FROM service_notes WHERE message_id = ? LIMIT 1').bind(r.m.id).first();
  if (used) return c.json({ error: 'This message has been pushed to a service and is kept for history' }, 409);
  await c.env.DB.prepare('DELETE FROM messages WHERE id = ?').bind(r.m.id).run();
  return c.json({ ok: true });
});

// The speaker's full notes ("Notes"): one PDF or Word file per message, kept in R2.
const NOTES_MAX = 20 * 1024 * 1024;
function notesKind(bytes: Uint8Array): { ext: string; type: string } | null {
  const head = [...bytes.subarray(0, 8)];
  if (new TextDecoder().decode(bytes.subarray(0, 5)) === '%PDF-') return { ext: 'pdf', type: 'application/pdf' };
  if (head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04)
    return { ext: 'docx', type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' };
  if ([0xd0, 0xcf, 0x11, 0xe0].every((b, i) => head[i] === b)) return { ext: 'doc', type: 'application/msword' };
  return null;
}
const cleanFileName = (s: string, ext: string) => {
  const base = s.replace(/\.[A-Za-z0-9]{1,5}$/, '').replace(/[^\p{L}\p{N} ._()&,'-]+/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 100) || 'Notes';
  return `${base}.${ext}`;
};

api.put('/messages/:id/notes', async (c) => {
  const r = await loadMessage(c, c.get('user'), c.req.param('id'));
  if ('error' in r) return c.json({ error: r.error }, r.status);
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength > NOTES_MAX) return c.json({ error: 'The notes file is over 20 MB' }, 413);
  const kind = notesKind(bytes);
  if (!kind) return c.json({ error: 'Notes must be a PDF or a Word document' }, 400);
  let name = c.req.header('X-File-Name') ?? '';
  try {
    name = decodeURIComponent(name);
  } catch {
    /* keep as sent */
  }
  name = cleanFileName(name, kind.ext);
  const key = `notes/${r.m.id}/${newId('n')}.${kind.ext}`;
  await c.env.PRIVATE.put(key, bytes, { httpMetadata: { contentType: kind.type } });
  // The old file stays if a push was sent with it.
  if (r.m.notes_key) {
    const used = await c.env.DB.prepare('SELECT 1 FROM service_notes WHERE notes_key = ? LIMIT 1').bind(r.m.notes_key).first();
    if (!used) await c.env.PRIVATE.delete(r.m.notes_key);
  }
  await c.env.DB.prepare('UPDATE messages SET notes_key = ?, notes_name = ?, notes_type = ?, notes_size = ?, updated_at = ? WHERE id = ?')
    .bind(key, name, kind.type, bytes.byteLength, now(), r.m.id)
    .run();
  return c.json({ notesFile: { name, type: kind.type, size: bytes.byteLength } });
});

api.delete('/messages/:id/notes', async (c) => {
  const r = await loadMessage(c, c.get('user'), c.req.param('id'));
  if ('error' in r) return c.json({ error: r.error }, r.status);
  if (r.m.notes_key) {
    const used = await c.env.DB.prepare('SELECT 1 FROM service_notes WHERE notes_key = ? LIMIT 1').bind(r.m.notes_key).first();
    if (!used) await c.env.PRIVATE.delete(r.m.notes_key);
  }
  await c.env.DB.prepare('UPDATE messages SET notes_key = NULL, notes_name = NULL, notes_type = NULL, notes_size = NULL, updated_at = ? WHERE id = ?')
    .bind(now(), r.m.id)
    .run();
  return c.json({ ok: true });
});

async function sendStored(c: { env: AppEnv['Bindings'] }, key: string, name: string, type: string, download: boolean) {
  const obj = await c.env.PRIVATE.get(key);
  if (!obj) return new Response(JSON.stringify({ error: 'File missing' }), { status: 404, headers: { 'Content-Type': 'application/json' } });
  const disp = `${download ? 'attachment' : 'inline'}; filename*=UTF-8''${encodeURIComponent(name)}`;
  return new Response(obj.body, { headers: { 'Content-Type': type, 'Content-Disposition': disp, 'Cache-Control': 'private, no-store' } });
}

api.get('/messages/:id/notes', async (c) => {
  const r = await loadMessage(c, c.get('user'), c.req.param('id'));
  if ('error' in r) return c.json({ error: r.error }, r.status);
  if (!r.m.notes_key) return c.json({ error: 'No notes file' }, 404);
  return sendStored(c, r.m.notes_key, r.m.notes_name ?? 'Notes', r.m.notes_type ?? 'application/octet-stream', r.m.notes_type !== 'application/pdf');
});

/** Keeps exactly the FORMAT.md slide shape. */
function cleanSlides(slides: Slide[]): Slide[] {
  return slides.map((s) => ({
    id: String(s.id),
    kind: (['scripture', 'point', 'quote'] as const).includes(s.kind) ? s.kind : 'point',
    style: s.style === 'big' ? 'big' : 'small',
    runs: (s.runs ?? []).filter((r) => typeof r.t === 'string' && r.t !== '').map((r) => (r.b ? { t: r.t, b: true } : { t: r.t })),
  }));
}

// Push
interface PushTarget {
  campusId: string;
  date: string; // YYYY-MM-DD (NZ)
  time: string; // HH:MM (NZ)
  label?: string; // "AM" / "PM" / ...
}

api.post('/push', async (c) => {
  const user = c.get('user');
  const b = await c.req.json<{ messageId: string; themeId?: string | null; targets: PushTarget[] }>();
  const r = await loadMessage(c, user, b.messageId);
  if ('error' in r) return c.json({ error: r.error }, r.status);
  const slides = cleanSlides(JSON.parse(r.m.slides_json));
  if (!slides.length) return c.json({ error: 'The message has no slides yet' }, 400);
  if (!Array.isArray(b.targets) || !b.targets.length) return c.json({ error: 'Choose at least one campus and service time' }, 400);
  if (b.themeId && !THEME_IDS.includes(b.themeId)) return c.json({ error: 'Unknown theme' }, 400);
  const db = c.env.DB;
  const out = [];
  for (const t of b.targets) {
    const campus = await db.prepare('SELECT id, name, default_theme_id FROM campuses WHERE id = ?').bind(t.campusId).first<{ id: string; name: string; default_theme_id: string }>();
    if (!campus) return c.json({ error: `Unknown campus ${t.campusId}` }, 400);
    let when;
    try {
      when = zonedToIso(t.date, t.time);
    } catch {
      return c.json({ error: 'Invalid date or time' }, 400);
    }
    const label = `${campus.name} ${(t.label ?? '').trim()}`.trim();
    let svc = await db.prepare('SELECT id, label FROM services WHERE campus_id = ? AND starts_utc = ?').bind(campus.id, when.utc).first<{ id: string; label: string }>();
    if (!svc) {
      svc = { id: newId('svc'), label };
      await db.prepare('INSERT INTO services (id, campus_id, starts_at, starts_utc, label, created_at) VALUES (?, ?, ?, ?, ?, ?)')
        .bind(svc.id, campus.id, when.iso, when.utc, label, now())
        .run();
    } else if (t.label && t.label.trim() && svc.label !== label) {
      await db.prepare('UPDATE services SET label = ? WHERE id = ?').bind(label, svc.id).run();
      svc.label = label;
    }
    const prev = await db.prepare('SELECT MAX(version) AS v FROM service_notes WHERE service_id = ?').bind(svc.id).first<{ v: number | null }>();
    const version = (prev?.v ?? 0) + 1;
    const themeId = b.themeId || campus.default_theme_id;
    const pushedAt = now();
    await db.prepare(
      `INSERT INTO service_notes (service_id, version, message_id, theme_id, title, speaker, slides_json, pushed_by, pushed_at, notes_key, notes_name, notes_type)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(svc.id, version, r.m.id, themeId, r.m.title, r.m.speaker, JSON.stringify(slides), user.email, pushedAt, r.m.notes_key, r.m.notes_name, r.m.notes_type)
      .run();
    out.push({ serviceId: svc.id, version, campusId: campus.id, campusName: campus.name, label: svc.label, startsAt: when.iso, themeId, pushedAt });
  }
  return c.json({ pushed: out });
});

/**
 * Who gets the push email. The campus list and the speaker go in To, so everyone can see it reached the
 * right people; whoever created the notes (and whoever pushed them, if someone else) gets a copy in Cc.
 * Nobody appears twice, and with no one else to send to the Cc people move to To.
 */
export function emailRecipients(campus: string[], speaker: string | null, copy: (string | null)[]) {
  const norm = (list: (string | null)[]) => [...new Set(list.filter((e): e is string => isEmail(e)).map((e) => e.trim().toLowerCase()))];
  const to = norm([...campus, speaker]);
  const cc = norm(copy).filter((e) => !to.includes(e));
  return to.length ? { to, cc } : { to: cc, cc: [] as string[] };
}

// ProPresenter bundle for a pushed version (built in the portal); emailed with the PDF that follows.
const PROBUNDLE_MAX = 15 * 1024 * 1024;
api.put('/services/:id/versions/:v/probundle', async (c) => {
  const user = c.get('user');
  const id = c.req.param('id');
  const version = Number(c.req.param('v'));
  const row = await c.env.DB.prepare('SELECT pushed_by FROM service_notes WHERE service_id = ? AND version = ?').bind(id, version).first<{ pushed_by: string }>();
  if (!row) return c.json({ error: 'No such push' }, 404);
  if (row.pushed_by !== user.email && !canSeeAll(user)) return c.json({ error: 'Not your push' }, 403);
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength > PROBUNDLE_MAX) return c.json({ error: 'ProPresenter bundle too large' }, 413);
  if (!(bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04)) return c.json({ error: 'Not a .probundle' }, 400);
  let name = c.req.header('X-File-Name') ?? '';
  try {
    name = decodeURIComponent(name);
  } catch {
    /* keep */
  }
  name = name.replace(/[\/:*?"<>|]+/g, ' ').trim().slice(0, 150) || 'Speaker Notes.probundle';
  if (!/\.probundle$/i.test(name)) name += '.probundle';
  const key = `probundles/${id}/v${version}.probundle`;
  await c.env.PRIVATE.put(key, bytes, { httpMetadata: { contentType: 'application/octet-stream' } });
  await c.env.DB.prepare('UPDATE service_notes SET probundle_key = ?, probundle_name = ? WHERE service_id = ? AND version = ?').bind(key, name, id, version).run();
  return c.json({ ok: true, name });
});

api.get('/services/:id/versions/:v/probundle', async (c) => {
  const row = await c.env.DB.prepare('SELECT probundle_key, probundle_name FROM service_notes WHERE service_id = ? AND version = ?')
    .bind(c.req.param('id'), Number(c.req.param('v')))
    .first<{ probundle_key: string | null; probundle_name: string | null }>();
  if (!row?.probundle_key) return c.json({ error: 'No ProPresenter bundle' }, 404);
  return sendStored(c, row.probundle_key, row.probundle_name ?? 'Speaker Notes.probundle', 'application/octet-stream', true);
});

// PDF for a pushed version: stored in R2, then emailed.
api.put('/services/:id/versions/:v/pdf', async (c) => {
  const user = c.get('user');
  const id = c.req.param('id');
  const version = Number(c.req.param('v'));
  const db = c.env.DB;
  const row = await db
    .prepare(
      `SELECT n.*, s.label, s.starts_at, s.campus_id, m.speaker_email, m.created_by
         FROM service_notes n JOIN services s ON s.id = n.service_id JOIN messages m ON m.id = n.message_id
        WHERE n.service_id = ? AND n.version = ?`,
    )
    .bind(id, version)
    .first<{ pushed_by: string; label: string; starts_at: string; campus_id: string; speaker_email: string | null; title: string; speaker: string; slides_json: string; message_id: string; created_by: string; probundle_key: string | null; probundle_name: string | null; notes_key: string | null; notes_name: string | null; notes_type: string | null }>();
  if (!row) return c.json({ error: 'No such push' }, 404);
  if (row.pushed_by !== user.email && !canSeeAll(user)) return c.json({ error: 'Not your push' }, 403);
  const pdf = new Uint8Array(await c.req.arrayBuffer());
  if (pdf.byteLength < 100 || new TextDecoder().decode(pdf.subarray(0, 5)) !== '%PDF-') return c.json({ error: 'Not a PDF' }, 400);
  if (pdf.byteLength > 20 * 1024 * 1024) return c.json({ error: 'PDF too large' }, 413);
  const key = `pdfs/${id}/v${version}.pdf`;
  await c.env.PRIVATE.put(key, pdf, { httpMetadata: { contentType: 'application/pdf' } });
  await db.prepare('UPDATE service_notes SET pdf_key = ? WHERE service_id = ? AND version = ?').bind(key, id, version).run();

  const { results: recips } = await db.prepare('SELECT email FROM campus_recipients WHERE campus_id = ?').bind(row.campus_id).all<{ email: string }>();
  const { to, cc } = emailRecipients(recips.map((r) => r.email), row.speaker_email, [row.created_by, user.email]);
  const safe = (s: string) => s.replace(/[^\w\- ]+/g, '').trim().replace(/\s+/g, '-') || 'notes';
  // LIFE naming: YYYY-MM-DD_Speaker_CampusService_MessageTitle (+ _v2… for updates)
  const base = `${[row.starts_at.slice(0, 10), safe(row.speaker), safe(row.label), safe(row.title)].join('_')}${version > 1 ? `_v${version}` : ''}`;
  // The full notes go along as an attachment when the email stays under Cloudflare's 25 MiB limit
  // (attachments grow by a third in base64); otherwise the email links to them in the portal.
  // The ProPresenter bundle comes first (campuses on the legacy setup need it to run the service).
  const BUDGET = 17 * 1024 * 1024;
  let used = pdf.byteLength;
  let probundle: { bytes: Uint8Array; name: string } | null = null;
  let probundleLink: string | null = null;
  if (row.probundle_key) {
    const obj = await c.env.PRIVATE.get(row.probundle_key);
    if (obj && used + obj.size <= BUDGET) {
      probundle = { bytes: new Uint8Array(await obj.arrayBuffer()), name: row.probundle_name ?? `${base}.probundle` };
      used += obj.size;
    } else if (obj) probundleLink = new URL(`/api/services/${id}/versions/${version}/probundle`, c.req.url).toString();
  }
  let notes: { bytes: Uint8Array; name: string; type: string } | null = null;
  let notesLink: string | null = null;
  if (row.notes_key) {
    const obj = await c.env.PRIVATE.get(row.notes_key);
    const ext = (row.notes_name ?? '').split('.').pop() || 'pdf';
    if (obj && obj.size + used <= BUDGET) {
      notes = { bytes: new Uint8Array(await obj.arrayBuffer()), name: `${base} - Notes.${ext}`, type: row.notes_type ?? 'application/pdf' };
    } else if (obj) {
      notesLink = new URL(`/api/services/${id}/versions/${version}/notes`, c.req.url).toString();
    }
  }
  try {
    const res = await sendNotesEmail(c.env, {
      to,
      cc,
      title: row.title,
      speaker: row.speaker,
      serviceLabel: row.label,
      startsAt: row.starts_at,
      version,
      pushedBy: user.email,
      slideCount: (JSON.parse(row.slides_json) as unknown[]).length,
      portalUrl: new URL(`/#/messages/${row.message_id}`, c.req.url).toString(),
      pdf,
      pdfName: `${base} - Slides Preview.pdf`,
      notes,
      notesLink,
      probundle,
      probundleLink,
    });
    await db.prepare('UPDATE service_notes SET emailed_at = ?, email_error = NULL WHERE service_id = ? AND version = ?')
      .bind(res.dryRun ? null : now(), id, version)
      .run();
    return c.json({ ok: true, pdfKey: key, recipients: [...to, ...cc], to, cc, ...res });
  } catch (e) {
    const msg = `${(e as { code?: string }).code ?? ''} ${(e as Error).message}`.trim();
    await db.prepare('UPDATE service_notes SET email_error = ? WHERE service_id = ? AND version = ?').bind(msg, id, version).run();
    return c.json({ ok: false, pdfKey: key, recipients: [...to, ...cc], to, cc, error: `PDF saved, but the email failed: ${msg}` }, 502);
  }
});

api.get('/services/:id/versions/:v/notes', async (c) => {
  const row = await c.env.DB.prepare('SELECT notes_key, notes_name, notes_type FROM service_notes WHERE service_id = ? AND version = ?')
    .bind(c.req.param('id'), Number(c.req.param('v')))
    .first<{ notes_key: string | null; notes_name: string | null; notes_type: string | null }>();
  if (!row?.notes_key) return c.json({ error: 'No notes file' }, 404);
  return sendStored(c, row.notes_key, row.notes_name ?? 'Notes', row.notes_type ?? 'application/octet-stream', row.notes_type !== 'application/pdf');
});

api.get('/services/:id/versions/:v/pdf', async (c) => {
  const row = await c.env.DB.prepare('SELECT pdf_key FROM service_notes WHERE service_id = ? AND version = ?')
    .bind(c.req.param('id'), Number(c.req.param('v')))
    .first<{ pdf_key: string | null }>();
  if (!row?.pdf_key) return c.json({ error: 'No PDF' }, 404);
  const obj = await c.env.PRIVATE.get(row.pdf_key);
  if (!obj) return c.json({ error: 'No PDF' }, 404);
  return new Response(obj.body, { headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': 'inline' } });
});

api.get('/services/:id', async (c) => {
  const pkg = await servicePackage(c.env.DB, c.req.param('id'));
  if (!pkg) return c.json({ error: 'No such service' }, 404);
  const { results: versions } = await c.env.DB.prepare(
    'SELECT version, message_id, title, theme_id, pushed_by, pushed_at, pdf_key IS NOT NULL AS has_pdf, notes_key IS NOT NULL AS has_notes, probundle_key IS NOT NULL AS has_probundle, notes_name, emailed_at, email_error FROM service_notes WHERE service_id = ? ORDER BY version DESC',
  )
    .bind(pkg.id)
    .all();
  return c.json({ service: pkg, versions });
});

/** Services view: upcoming (default) or recent past services, plus the Macs per campus. */
api.get('/services', async (c) => {
  const past = c.req.query('range') === 'past';
  const cutoff = new Date(Date.now() - 12 * 3600_000).toISOString();
  const rows = await listServices(c.env.DB, past ? { toUtc: cutoff, desc: true } : { fromUtc: cutoff });
  const { results: devices } = await c.env.DB.prepare(
    'SELECT id, name, campus_id, control_url, last_seen, app_version, loaded_service_id, loaded_version FROM devices ORDER BY name',
  ).all();
  return c.json({
    services: rows.map((r) => ({ ...summary(r), messageId: r.message_id, pushedBy: r.pushed_by, hasPdf: !!r.pdf_key, hasNotes: !!r.notes_key, hasProbundle: !!r.probundle_key, emailedAt: r.emailed_at, emailError: r.email_error })),
    devices,
  });
});

// Machines
api.get('/devices', requireRole('admin', 'production'), async (c) => {
  const { results } = await c.env.DB.prepare(
    'SELECT id, name, campus_id, control_url, created_by, created_at, last_seen, app_version, loaded_service_id, loaded_version FROM devices ORDER BY name',
  ).all();
  return c.json({ devices: results });
});

api.post('/devices', requireRole('admin'), async (c) => {
  const b = await c.req.json<{ name: string; campusId: string; controlUrl?: string }>();
  if (!b.name?.trim()) return c.json({ error: 'Name required' }, 400);
  const campus = await c.env.DB.prepare('SELECT id FROM campuses WHERE id = ?').bind(b.campusId).first();
  if (!campus) return c.json({ error: 'Unknown campus' }, 400);
  const token = `lcg_${b64url(crypto.getRandomValues(new Uint8Array(32)))}`;
  const id = newId('dev');
  await c.env.DB.prepare('INSERT INTO devices (id, name, campus_id, token_hash, control_url, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .bind(id, b.name.trim(), b.campusId, await sha256Hex(token), b.controlUrl?.trim() || null, c.get('user').email, now())
    .run();
  return c.json({ device: { id, name: b.name.trim(), campusId: b.campusId }, token }, 201);
});

api.patch('/devices/:id', requireRole('admin'), async (c) => {
  const b = await c.req.json<{ name?: string; campusId?: string; controlUrl?: string | null }>();
  if (b.controlUrl && !/^https?:\/\//.test(b.controlUrl)) return c.json({ error: 'Control URL must start with http://' }, 400);
  await c.env.DB.prepare(
    'UPDATE devices SET name = COALESCE(?, name), campus_id = COALESCE(?, campus_id), control_url = CASE WHEN ? THEN ? ELSE control_url END WHERE id = ?',
  )
    .bind(b.name?.trim() || null, b.campusId || null, b.controlUrl !== undefined ? 1 : 0, b.controlUrl?.trim() || null, c.req.param('id'))
    .run();
  return c.json({ ok: true });
});

api.post('/devices/:id/token', requireRole('admin'), async (c) => {
  const token = `lcg_${b64url(crypto.getRandomValues(new Uint8Array(32)))}`;
  const r = await c.env.DB.prepare('UPDATE devices SET token_hash = ? WHERE id = ?').bind(await sha256Hex(token), c.req.param('id')).run();
  if (!r.meta.changes) return c.json({ error: 'No such device' }, 404);
  return c.json({ token });
});

api.delete('/devices/:id', requireRole('admin'), async (c) => {
  await c.env.DB.prepare('DELETE FROM devices WHERE id = ?').bind(c.req.param('id')).run();
  return c.json({ ok: true });
});

app.route('/api', api);
app.all('/api/*', (c) => c.json({ error: 'Not found' }, 404));

// Everything else: the portal's static files.
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw));

export default app;
