import { useEffect, useState } from 'preact/hooks';
import { api } from '../api';
import { ago, canSeeAll, useMe } from '../state';

interface Row {
  id: string;
  title: string;
  speaker: string;
  created_by: string;
  updated_at: string;
  slide_count: number;
  push_count: number;
}

export function MessagesPage() {
  const me = useMe();
  const [q, setQ] = useState('');
  const [scope, setScope] = useState<'mine' | 'all'>(canSeeAll(me) ? 'all' : 'mine');
  const [rows, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const t = setTimeout(() => {
      api<{ messages: Row[] }>(`/messages?scope=${scope}&q=${encodeURIComponent(q)}`).then((r) => setRows(r.messages), (e) => setErr(e.message));
    }, 200);
    return () => clearTimeout(t);
  }, [q, scope]);

  const create = async () => {
    const r = await api<{ message: { id: string } }>('/messages', { body: {} });
    location.hash = `#/messages/${r.message.id}`;
  };

  return (
    <section class="page">
      <div class="page-head">
        <h1>Messages</h1>
        <button class="primary" onClick={create}>
          New message
        </button>
      </div>
      <div class="toolbar">
        <input type="search" placeholder="Search title, speaker or text" value={q} onInput={(e) => setQ(e.currentTarget.value)} />
        {canSeeAll(me) && (
          <div class="seg">
            <button class={scope === 'mine' ? 'on' : ''} onClick={() => setScope('mine')}>
              Mine
            </button>
            <button class={scope === 'all' ? 'on' : ''} onClick={() => setScope('all')}>
              All
            </button>
          </div>
        )}
      </div>
      {err && <p class="error">{err}</p>}
      {rows && rows.length === 0 && <p class="empty">No messages yet. Start with “New message”.</p>}
      {rows && rows.length > 0 && (
        <ul class="list">
          {rows.map((m) => (
            <li key={m.id}>
              <a href={`#/messages/${m.id}`} class="row-link">
                <div>
                  <div class="row-title">{m.title || 'Untitled'}</div>
                  <div class="muted">
                    {m.speaker || 'No speaker'} · {m.slide_count} slides
                    {m.push_count > 0 && ` · pushed to ${m.push_count} service${m.push_count > 1 ? 's' : ''}`}
                  </div>
                </div>
                <div class="muted right">
                  {ago(m.updated_at)}
                  {m.created_by !== me.user.email && <div class="small">{m.created_by}</div>}
                </div>
              </a>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
