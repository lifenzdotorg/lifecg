import { useEffect, useState } from 'preact/hooks';
import { THEMES } from '../../../shared/themes';
import { formatServiceDate, zonedToIso } from '../../../shared/time';
import type { Slide, Theme } from '../../../shared/types';
import { api } from '../api';
import { loadFonts } from '../fonts';
import { buildNotesPdf } from '../pdf';
import { nextSunday, useCampuses, useMe } from '../state';

interface Target {
  campusId: string;
  date: string;
  time: string;
  label: string;
  /** email a ProPresenter .probundle; unset = the campus's setting */
  probundle?: boolean;
}

interface Pushed {
  serviceId: string;
  version: number;
  campusId: string;
  campusName: string;
  label: string;
  startsAt: string;
  themeId: string;
}

interface Upcoming {
  id: string;
  campusId: string;
  startsAt: string;
  label: string;
  title: string;
  version: number;
}

type Result = Pushed & { state: 'bundle' | 'pdf' | 'email' | 'done' | 'error'; note?: string };

type BundleModule = typeof import('../probundleEntry');
let bundleModule: Promise<BundleModule> | null = null;
declare const __PROBUNDLE_VER__: string;
const PROBUNDLE_URL = `/probundle.js?v=${__PROBUNDLE_VER__}`;
const loadBundleModule = () => (bundleModule ??= import(/* @vite-ignore */ PROBUNDLE_URL) as Promise<BundleModule>);

/** ProPresenter naming used by LIFE: `2026 11 15 II CENTRAL PM II Speaker - Title` */
export function presentationName(startsAt: string, label: string, speaker: string, title: string): string {
  const who = [speaker.trim(), title.trim()].filter(Boolean).join(' - ') || 'Speaker Notes';
  return `${startsAt.slice(0, 10).replace(/-/g, ' ')} II ${label.trim().toUpperCase()} II ${who}`;
}

async function makeBundle(theme: Theme, slides: Slide[], name: string): Promise<{ fileName: string; bytes: Uint8Array }> {
  const { buildProBundle } = await loadBundleModule();
  const media = await Promise.all(
    theme.layers
      .filter((l) => l.type === 'image' && l.src)
      .map(async (l) => {
        const res = await fetch(`/themes/${theme.id}/${l.src}`);
        if (!res.ok) throw new Error(`Couldn’t load the ${theme.name} background`);
        return { src: l.src!, bytes: new Uint8Array(await res.arrayBuffer()) };
      }),
  );
  return buildProBundle({ name, slides, theme, media });
}

const DEFAULT_TIMES: Record<string, string> = { AM: '09:30', PM: '18:00' };

export function PushDialog({ messageId, initial, onClose }: { messageId: string; initial?: Partial<Target>; onClose: (pushed: boolean) => void }) {
  const me = useMe();
  const [campuses] = useCampuses();
  const [message, setMessage] = useState<{ title: string; speaker: string; slides: Slide[] } | null>(null);
  const [upcoming, setUpcoming] = useState<Upcoming[]>([]);
  const [targets, setTargets] = useState<Target[]>([
    { campusId: initial?.campusId ?? 'central', date: initial?.date ?? nextSunday(), time: initial?.time ?? '09:30', label: initial?.label ?? 'AM' },
  ]);
  const [themeId, setThemeId] = useState('');
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<Result[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    api(`/messages/${messageId}`).then((r) => setMessage(r.message), (e) => setErr(e.message));
    api('/services').then((r) => setUpcoming(r.services));
  }, [messageId]);

  const setT = (i: number, patch: Partial<Target>) => setTargets(targets.map((t, j) => (j === i ? { ...t, ...patch } : t)));

  const existing = (t: Target) => {
    try {
      const { iso } = zonedToIso(t.date, t.time);
      return upcoming.find((u) => u.campusId === t.campusId && Date.parse(u.startsAt) === Date.parse(iso));
    } catch {
      return undefined;
    }
  };

  const push = async () => {
    if (!message) return;
    setBusy(true);
    setErr(null);
    try {
      const r = await api<{ pushed: Pushed[] }>('/push', { body: { messageId, themeId: themeId || null, targets } });
      let res: Result[] = r.pushed.map((p) => ({ ...p, state: 'pdf' }));
      setResults(res);
      const fonts = await loadFonts();
      for (const [i, p] of r.pushed.entries()) {
        const upd = (patch: Partial<Result>) => {
          res = res.map((x, j) => (j === i ? { ...x, ...patch } : x));
          setResults(res);
        };
        try {
          const target = targets[i];
          const campus = campuses?.find((c) => c.id === p.campusId);
          if (target?.probundle ?? !!campus?.send_probundle) {
            upd({ state: 'bundle' });
            const b = await makeBundle(THEMES[p.themeId] ?? THEMES.central, message.slides, presentationName(p.startsAt, p.label, message.speaker, message.title));
            await api(`/services/${p.serviceId}/versions/${p.version}/probundle`, {
              method: 'PUT',
              raw: b.bytes as BodyInit,
              contentType: 'application/octet-stream',
              headers: { 'X-File-Name': encodeURIComponent(b.fileName) },
            });
            upd({ state: 'pdf' });
          }
          const pdf = await buildNotesPdf(
            { title: message.title, speaker: message.speaker, serviceLabel: p.label, startsAt: p.startsAt, version: p.version, pushedBy: me.user.email },
            message.slides,
            THEMES[p.themeId] ?? THEMES.central,
            fonts,
          );
          upd({ state: 'email' });
          const e = await api(`/services/${p.serviceId}/versions/${p.version}/pdf`, { method: 'PUT', raw: pdf as BodyInit, contentType: 'application/pdf' });
          upd({
            state: 'done',
            note: e.dryRun ? `PDF saved · email logged (dry run) to ${e.recipients.length}` : `PDF emailed to ${e.recipients.length} recipient${e.recipients.length === 1 ? '' : 's'}`,
          });
        } catch (e) {
          upd({ state: 'error', note: (e as Error).message });
        }
      }
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="modal-back" onClick={(e) => e.target === e.currentTarget && !busy && onClose(!!results)}>
      <div class="modal" role="dialog" aria-label="Push notes">
        <h2>Push “{message?.title || 'Untitled'}”</h2>
        {!results && (
          <>
            <p class="hint">
              The Mac at each campus downloads the slides; the Slides Preview PDF goes to the campus list and the speaker, with a copy to whoever created the
              notes. Tick “Email .probundle” for a campus still building its notes in ProPresenter.
            </p>
            <div class="targets">
              {targets.map((t, i) => {
                const ex = existing(t);
                return (
                  <div class="target" key={i}>
                    <select value={t.campusId} onChange={(e) => setT(i, { campusId: e.currentTarget.value, probundle: undefined })} aria-label="Campus">
                      {campuses?.map((c) => (
                        <option value={c.id}>{c.name}</option>
                      ))}
                    </select>
                    <input type="date" value={t.date} onInput={(e) => setT(i, { date: e.currentTarget.value })} aria-label="Date" />
                    <input type="time" value={t.time} step={300} onInput={(e) => setT(i, { time: e.currentTarget.value })} aria-label="Time" />
                    <input
                      class="label-in"
                      list="svc-labels"
                      value={t.label}
                      placeholder="AM"
                      onInput={(e) => {
                        const label = e.currentTarget.value;
                        setT(i, DEFAULT_TIMES[label] ? { label, time: DEFAULT_TIMES[label] } : { label });
                      }}
                      aria-label="Service label"
                    />
                    <label class="inline-check bundle-check">
                      <input
                        type="checkbox"
                        checked={t.probundle ?? !!campuses?.find((c) => c.id === t.campusId)?.send_probundle}
                        onChange={(e) => setT(i, { probundle: e.currentTarget.checked })}
                      />
                      Email .probundle
                    </label>
                    {targets.length > 1 && (
                      <button class="icon" onClick={() => setTargets(targets.filter((_, j) => j !== i))} aria-label="Remove">
                        ×
                      </button>
                    )}
                    <div class="target-note">
                      {ex ? (
                        <span class="warn-text">
                          Push Update: {ex.label} already has “{ex.title}” v{ex.version} → v{ex.version + 1}
                        </span>
                      ) : (
                        <span class="muted">New service</span>
                      )}
                    </div>
                  </div>
                );
              })}
              <datalist id="svc-labels">
                <option value="AM" />
                <option value="PM" />
              </datalist>
            </div>
            <button class="link" onClick={() => setTargets([...targets, { ...targets[targets.length - 1], probundle: undefined }])}>
              + Another campus or service
            </button>
            <label class="inline theme-override">
              Theme
              <select value={themeId} onChange={(e) => setThemeId(e.currentTarget.value)}>
                <option value="">Campus default</option>
                {Object.values(THEMES).map((t) => (
                  <option value={t.id}>{t.name}</option>
                ))}
              </select>
            </label>
            {err && <p class="error">{err}</p>}
            <div class="modal-actions">
              <button onClick={() => onClose(false)} disabled={busy}>
                Cancel
              </button>
              <button class="primary" onClick={push} disabled={busy || !message || !campuses}>
                {busy ? 'Pushing…' : targets.some((t) => existing(t)) ? 'Push Update' : 'Push'}
              </button>
            </div>
          </>
        )}
        {results && (
          <>
            <ul class="results">
              {results.map((r) => (
                <li key={r.serviceId} class={`res-${r.state}`}>
                  <strong>
                    {r.label} · {formatServiceDate(r.startsAt)}
                  </strong>{' '}
                  v{r.version} · {THEMES[r.themeId]?.name}
                  <div class="small">
                    {r.state === 'bundle' && 'Making ProPresenter bundle…'}
                    {r.state === 'pdf' && 'Making PDF…'}
                    {r.state === 'email' && 'Uploading and emailing…'}
                    {(r.state === 'done' || r.state === 'error') && r.note}
                  </div>
                </li>
              ))}
            </ul>
            {err && <p class="error">{err}</p>}
            <div class="modal-actions">
              <button class="primary" onClick={() => onClose(true)} disabled={busy}>
                Done
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
