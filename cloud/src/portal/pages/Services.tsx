import { useEffect, useState } from 'preact/hooks';
import { THEMES } from '../../../shared/themes';
import { formatServiceDate } from '../../../shared/time';
import { api } from '../api';
import { ago, nextSunday, useCampuses } from '../state';
import { PushDialog } from './Push';

interface Svc {
  id: string;
  campusId: string;
  campusName: string;
  label: string;
  startsAt: string;
  themeId: string;
  title: string;
  speaker: string;
  version: number;
  updatedAt: string;
  messageId: string;
  pushedBy: string;
  hasPdf: boolean;
  hasNotes?: boolean;
  hasProbundle?: boolean;
  emailedAt: string | null;
  emailError: string | null;
}

interface Dev {
  id: string;
  name: string;
  campus_id: string;
  control_url: string | null;
  last_seen: string | null;
  app_version: string | null;
  loaded_service_id: string | null;
  loaded_version: number | null;
}

export function ServicesPage() {
  const [campuses] = useCampuses();
  const [range, setRange] = useState<'upcoming' | 'past'>('upcoming');
  const [data, setData] = useState<{ services: Svc[]; devices: Dev[] } | null>(null);
  const [repush, setRepush] = useState<{ messageId: string; campusId: string; label: string; time: string } | null>(null);

  const load = () => api(`/services?range=${range}`).then(setData);
  useEffect(() => {
    load();
  }, [range]);

  if (!campuses || !data) return <section class="page"><p class="muted">Loading…</p></section>;

  return (
    <section class="page">
      <div class="page-head">
        <h1>Services</h1>
        <div class="seg">
          <button class={range === 'upcoming' ? 'on' : ''} onClick={() => setRange('upcoming')}>
            Upcoming
          </button>
          <button class={range === 'past' ? 'on' : ''} onClick={() => setRange('past')}>
            Past
          </button>
        </div>
      </div>
      <div class="campus-grid">
        {campuses.map((c) => {
          const svcs = data.services.filter((s) => s.campusId === c.id);
          const devs = data.devices.filter((d) => d.campus_id === c.id);
          return (
            <div class="campus-card" key={c.id}>
              <div class="campus-head">
                <h2>{c.name}</h2>
                <span class="muted small">{THEMES[c.default_theme_id]?.name ?? c.default_theme_id} theme</span>
              </div>
              {devs.map((d) => {
                const loaded = data.services.find((s) => s.id === d.loaded_service_id);
                const current = loaded && loaded.version === d.loaded_version;
                return (
                  <div class="device-line" key={d.id}>
                    <span class={`dot ${d.last_seen && Date.now() - Date.parse(d.last_seen) < 120_000 ? 'on' : ''}`} />
                    <span>{d.name}</span>
                    <span class="muted small">
                      seen {ago(d.last_seen)}
                      {loaded && ` · showing ${loaded.label} v${d.loaded_version}${current ? '' : ' (update available)'}`}
                    </span>
                    {d.control_url && (
                      <a class="control" href={d.control_url} target="_blank" rel="noopener" title="Works only on the church LAN">
                        Control ↗
                      </a>
                    )}
                  </div>
                );
              })}
              {svcs.length === 0 && <p class="muted small">No {range} services.</p>}
              <ul class="svc-list">
                {svcs.map((s) => (
                  <li key={s.id}>
                    <div class="svc-when">
                      <strong>{formatServiceDate(s.startsAt)}</strong> <span class="muted">{s.label}</span>
                    </div>
                    <div>
                      <a href={`#/messages/${s.messageId}`}>{s.title || 'Untitled'}</a> <span class="muted">· {s.speaker}</span>
                    </div>
                    <div class="muted small">
                      v{s.version} · {THEMES[s.themeId]?.name} · {s.pushedBy} {ago(s.updatedAt)}
                      {s.emailError && <span class="warn-text"> · email failed</span>}
                    </div>
                    <div class="svc-actions">
                      {s.hasPdf && (
                        <a href={`/api/services/${s.id}/versions/${s.version}/pdf`} target="_blank" rel="noopener">
                          Slides Preview
                        </a>
                      )}
                      {s.hasProbundle && <a href={`/api/services/${s.id}/versions/${s.version}/probundle`}>.probundle</a>}
                      {s.hasNotes && (
                        <a href={`/api/services/${s.id}/versions/${s.version}/notes`} target="_blank" rel="noopener">
                          Notes
                        </a>
                      )}
                      <button
                        class="link"
                        onClick={() => setRepush({ messageId: s.messageId, campusId: s.campusId, label: s.label.replace(`${s.campusName}`, '').trim(), time: s.startsAt.slice(11, 16) })}
                      >
                        Push again…
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            </div>
          );
        })}
      </div>
      {repush && (
        <PushDialog
          messageId={repush.messageId}
          initial={{ campusId: repush.campusId, date: nextSunday(), time: repush.time, label: repush.label }}
          onClose={(pushed) => {
            setRepush(null);
            if (pushed) load();
          }}
        />
      )}
    </section>
  );
}
