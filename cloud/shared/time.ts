// Service times are entered as NZ local date + time and stored with their UTC offset.
export const SERVICE_TZ = 'Pacific/Auckland';

function offsetMinutes(utcMs: number, tz: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(utcMs));
  const p = (t: string) => Number(parts.find((x) => x.type === t)!.value);
  return (Date.UTC(p('year'), p('month') - 1, p('day'), p('hour'), p('minute'), p('second')) - utcMs) / 60000;
}

/** `2026-11-15`, `09:30` -> { iso: '2026-11-15T09:30:00+13:00', utc: '2026-11-14T20:30:00.000Z' } */
export function zonedToIso(date: string, time: string, tz = SERVICE_TZ): { iso: string; utc: string } {
  const dm = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  const tm = /^(\d{1,2}):(\d{2})$/.exec(time);
  if (!dm || !tm) throw new Error('bad date/time');
  const local = Date.UTC(+dm[1], +dm[2] - 1, +dm[3], +tm[1], +tm[2]);
  let utc = local - offsetMinutes(local, tz) * 60000;
  utc = local - offsetMinutes(utc, tz) * 60000;
  const off = offsetMinutes(utc, tz);
  const sign = off >= 0 ? '+' : '-';
  const a = Math.abs(off);
  const hh = String(Math.floor(a / 60)).padStart(2, '0');
  const mm = String(a % 60).padStart(2, '0');
  return { iso: `${date}T${tm[1].padStart(2, '0')}:${tm[2]}:00${sign}${hh}:${mm}`, utc: new Date(utc).toISOString() };
}

/** Local date/time parts of an ISO string with offset, as written (no conversion). */
export function isoParts(iso: string): { date: string; time: string } {
  return { date: iso.slice(0, 10), time: iso.slice(11, 16) };
}

export function formatServiceDate(iso: string): string {
  const { date, time } = isoParts(iso);
  const d = new Date(`${date}T12:00:00Z`);
  const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MO = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const day = `${WD[d.getUTCDay()]} ${d.getUTCDate()} ${MO[d.getUTCMonth()]}`;
  const [h, m] = time.split(':').map(Number);
  const t = `${((h + 11) % 12) + 1}${m ? ':' + String(m).padStart(2, '0') : ''}${h < 12 ? 'am' : 'pm'}`;
  return `${day} ${t}`;
}
