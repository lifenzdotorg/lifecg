// Service lists and packages (FORMAT.md "Service package" / "Device API").
import type { Slide } from '../../shared/types';

export interface ServiceRow {
  id: string;
  campus_id: string;
  campus_name: string;
  label: string;
  starts_at: string;
  starts_utc: string;
  version: number;
  theme_id: string;
  title: string;
  speaker: string;
  message_id: string;
  pushed_at: string;
  pushed_by: string;
  pdf_key: string | null;
  notes_key: string | null;
  probundle_key: string | null;
  emailed_at: string | null;
  email_error: string | null;
}

const LATEST = `
  SELECT s.id, s.campus_id, c.name AS campus_name, s.label, s.starts_at, s.starts_utc,
         n.version, n.theme_id, n.title, n.speaker, n.message_id, n.pushed_at, n.pushed_by,
         n.pdf_key, n.notes_key, n.probundle_key, n.emailed_at, n.email_error
    FROM services s
    JOIN campuses c ON c.id = s.campus_id
    JOIN service_notes n ON n.service_id = s.id
     AND n.version = (SELECT MAX(version) FROM service_notes WHERE service_id = s.id)`;

/** Services (with their latest notes) starting at or after `fromUtc`, soonest first. */
export async function listServices(db: D1Database, opts: { fromUtc?: string; toUtc?: string; campusId?: string; messageId?: string; desc?: boolean }) {
  const where: string[] = [];
  const args: unknown[] = [];
  if (opts.fromUtc) where.push('s.starts_utc >= ?'), args.push(opts.fromUtc);
  if (opts.toUtc) where.push('s.starts_utc < ?'), args.push(opts.toUtc);
  if (opts.campusId) where.push('s.campus_id = ?'), args.push(opts.campusId);
  if (opts.messageId) where.push('s.id IN (SELECT service_id FROM service_notes WHERE message_id = ?)'), args.push(opts.messageId);
  const sql = `${LATEST} ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY s.starts_utc ${opts.desc ? 'DESC' : 'ASC'} LIMIT 200`;
  const { results } = await db.prepare(sql).bind(...args).all<ServiceRow>();
  return results;
}

export function summary(r: ServiceRow) {
  return {
    id: r.id,
    campusId: r.campus_id,
    campusName: r.campus_name,
    label: r.label,
    startsAt: r.starts_at,
    themeId: r.theme_id,
    title: r.title,
    speaker: r.speaker,
    version: r.version,
    updatedAt: r.pushed_at,
  };
}

/** The full package a Mac downloads. */
export async function servicePackage(db: D1Database, id: string) {
  const row = await db
    .prepare(`${LATEST} WHERE s.id = ?`)
    .bind(id)
    .first<ServiceRow>();
  if (!row) return null;
  const notes = await db
    .prepare('SELECT slides_json FROM service_notes WHERE service_id = ? AND version = ?')
    .bind(id, row.version)
    .first<{ slides_json: string }>();
  const slides = JSON.parse(notes!.slides_json) as Slide[];
  return {
    id: row.id,
    campusId: row.campus_id,
    campusName: row.campus_name,
    label: row.label,
    startsAt: row.starts_at,
    themeId: row.theme_id,
    messageId: row.message_id,
    title: row.title,
    speaker: row.speaker,
    version: row.version,
    updatedAt: row.pushed_at,
    slides,
  };
}
