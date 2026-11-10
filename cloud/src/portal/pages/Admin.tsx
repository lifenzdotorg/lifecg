import { useEffect, useState } from 'preact/hooks';
import { THEMES } from '../../../shared/themes';
import { api } from '../api';
import { ago, type Campus, useCampuses } from '../state';

export function AdminPage() {
  const [tab, setTab] = useState<'campuses' | 'users' | 'machines'>('campuses');
  return (
    <section class="page">
      <div class="page-head">
        <h1>Admin</h1>
        <div class="seg">
          {(['campuses', 'users', 'machines'] as const).map((t) => (
            <button class={tab === t ? 'on' : ''} onClick={() => setTab(t)}>
              {t[0].toUpperCase() + t.slice(1)}
            </button>
          ))}
        </div>
      </div>
      {tab === 'campuses' && <Campuses />}
      {tab === 'users' && <Users />}
      {tab === 'machines' && <Machines />}
    </section>
  );
}

const run = async (f: () => Promise<unknown>, after: () => void) => {
  try {
    await f();
    after();
  } catch (e) {
    alert((e as Error).message);
  }
};

function Campuses() {
  const [campuses, reload] = useCampuses();
  if (!campuses) return <p class="muted">Loading…</p>;
  return (
    <div class="campus-grid">
      {campuses.map((c) => (
        <CampusCard key={c.id} c={c} reload={reload} />
      ))}
    </div>
  );
}

function CampusCard({ c, reload }: { c: Campus; reload: () => void }) {
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  return (
    <div class="campus-card">
      <div class="campus-head">
        <h2>{c.name}</h2>
        <select
          value={c.default_theme_id}
          onChange={(e) => run(() => api(`/campuses/${c.id}`, { method: 'PATCH', body: { default_theme_id: e.currentTarget.value } }), reload)}
          aria-label="Default theme"
        >
          {Object.values(THEMES).map((t) => (
            <option value={t.id}>{t.name} theme</option>
          ))}
        </select>
      </div>
      <label class="inline-check">
        <input
          type="checkbox"
          checked={!!c.send_probundle}
          onChange={(e) => run(() => api(`/campuses/${c.id}`, { method: 'PATCH', body: { send_probundle: e.currentTarget.checked } }), reload)}
        />
        Email a ProPresenter .probundle with each push (legacy setup)
      </label>
      <div class="small muted">Emailed on push (To, with the speaker; whoever created the notes gets a copy in Cc)</div>
      <ul class="recips">
        {c.recipients.map((r) => (
          <li key={r.email}>
            <span>
              {r.name && <strong>{r.name} </strong>}
              {r.email}
            </span>
            <button class="icon" aria-label={`Remove ${r.email}`} onClick={() => run(() => api(`/campuses/${c.id}/recipients/${encodeURIComponent(r.email)}`, { method: 'DELETE' }), reload)}>
              ×
            </button>
          </li>
        ))}
        {c.recipients.length === 0 && <li class="muted small">Nobody yet</li>}
      </ul>
      <form
        class="add-row"
        onSubmit={(e) => {
          e.preventDefault();
          run(() => api(`/campuses/${c.id}/recipients`, { body: { email, name } }), () => {
            setEmail('');
            setName('');
            reload();
          });
        }}
      >
        <input type="email" placeholder="email" value={email} onInput={(e) => setEmail(e.currentTarget.value)} required />
        <input placeholder="name (optional)" value={name} onInput={(e) => setName(e.currentTarget.value)} />
        <button type="submit">Add</button>
      </form>
    </div>
  );
}

interface UserRow {
  email: string;
  role: string;
  last_seen: string | null;
}

function Users() {
  const [users, setUsers] = useState<UserRow[] | null>(null);
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('pa');
  const load = () => api('/users').then((r) => setUsers(r.users));
  useEffect(() => {
    load();
  }, []);
  if (!users) return <p class="muted">Loading…</p>;
  return (
    <div class="card">
      <p class="hint">Anyone with a @lifenz.org login gets PA access on first sign-in. Operator is a PA who can also run the CG Macs' control page by signing in with their LIFE login. Production sees and pushes all messages; Admin also manages campuses, users and machines.</p>
      <table class="table">
        <thead>
          <tr>
            <th>Email</th>
            <th>Role</th>
            <th>Last seen</th>
          </tr>
        </thead>
        <tbody>
          {users.map((u) => (
            <tr key={u.email}>
              <td>{u.email}</td>
              <td>
                <select value={u.role} onChange={(e) => run(() => api(`/users/${encodeURIComponent(u.email)}`, { method: 'PATCH', body: { role: e.currentTarget.value } }), load)}>
                  <option value="pa">PA</option>
                  <option value="operator">Operator</option>
                  <option value="production">Production</option>
                  <option value="admin">Admin</option>
                </select>
              </td>
              <td class="muted">{ago(u.last_seen)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <form
        class="add-row"
        onSubmit={(e) => {
          e.preventDefault();
          run(() => api('/users', { body: { email, role } }), () => {
            setEmail('');
            load();
          });
        }}
      >
        <input type="email" placeholder="email" value={email} onInput={(e) => setEmail(e.currentTarget.value)} required />
        <select value={role} onChange={(e) => setRole(e.currentTarget.value)}>
          <option value="pa">PA</option>
          <option value="operator">Operator</option>
          <option value="production">Production</option>
          <option value="admin">Admin</option>
        </select>
        <button type="submit">Add user</button>
      </form>
    </div>
  );
}

interface DeviceRow {
  id: string;
  name: string;
  campus_id: string;
  control_url: string | null;
  last_seen: string | null;
  app_version: string | null;
  loaded_service_id: string | null;
  loaded_version: number | null;
}

function Machines() {
  const [campuses] = useCampuses();
  const [devices, setDevices] = useState<DeviceRow[] | null>(null);
  const [form, setForm] = useState({ name: '', campusId: 'central', controlUrl: '' });
  const [token, setToken] = useState<{ name: string; token: string } | null>(null);
  const load = () => api('/devices').then((r) => setDevices(r.devices));
  useEffect(() => {
    load();
  }, []);
  if (!devices || !campuses) return <p class="muted">Loading…</p>;
  const campusName = (id: string) => campuses.find((c) => c.id === id)?.name ?? id;
  return (
    <div class="card">
      {token && (
        <div class="token-box">
          <div>
            <strong>Token for {token.name}</strong>: copy it into LifeCG → Settings → Notes now. It won’t be shown again.
          </div>
          <code>{token.token}</code>
          <div>
            <button onClick={() => navigator.clipboard?.writeText(token.token)}>Copy</button> <button onClick={() => setToken(null)}>Done</button>
          </div>
        </div>
      )}
      <table class="table">
        <thead>
          <tr>
            <th>Machine</th>
            <th>Campus</th>
            <th>Last seen</th>
            <th>Loaded</th>
            <th>Control URL (LAN)</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {devices.map((d) => (
            <tr key={d.id}>
              <td>
                {d.name}
                <div class="small muted">{d.app_version ? `LifeCG ${d.app_version}` : 'not connected yet'}</div>
              </td>
              <td>
                <select value={d.campus_id} onChange={(e) => run(() => api(`/devices/${d.id}`, { method: 'PATCH', body: { campusId: e.currentTarget.value } }), load)}>
                  {campuses.map((c) => (
                    <option value={c.id}>{c.name}</option>
                  ))}
                </select>
              </td>
              <td class="muted">{ago(d.last_seen)}</td>
              <td class="small">{d.loaded_service_id ? `${d.loaded_service_id.slice(0, 14)}… v${d.loaded_version}` : '-'}</td>
              <td>
                <input
                  class="url-in"
                  placeholder="http://10.0.0.20:9123/control"
                  value={d.control_url ?? ''}
                  onChange={(e) => run(() => api(`/devices/${d.id}`, { method: 'PATCH', body: { controlUrl: e.currentTarget.value || null } }), load)}
                />
              </td>
              <td class="nowrap">
                <button
                  class="link"
                  onClick={() =>
                    confirm(`Make a new token for ${d.name}? The old one stops working.`) &&
                    run(() => api(`/devices/${d.id}/token`, { method: 'POST' }).then((r) => setToken({ name: d.name, token: r.token })), load)
                  }
                >
                  New token
                </button>{' '}
                <button class="link danger-text" onClick={() => confirm(`Remove ${d.name}?`) && run(() => api(`/devices/${d.id}`, { method: 'DELETE' }), load)}>
                  Remove
                </button>
              </td>
            </tr>
          ))}
          {devices.length === 0 && (
            <tr>
              <td colSpan={6} class="muted">
                No machines yet.
              </td>
            </tr>
          )}
        </tbody>
      </table>
      <h3>Add a machine</h3>
      <form
        class="add-row"
        onSubmit={(e) => {
          e.preventDefault();
          run(
            () =>
              api('/devices', { body: form }).then((r) => {
                setToken({ name: r.device.name, token: r.token });
              }),
            () => {
              setForm({ ...form, name: '', controlUrl: '' });
              load();
            },
          );
        }}
      >
        <input placeholder="Name, e.g. Central CG Mac" value={form.name} onInput={(e) => setForm({ ...form, name: e.currentTarget.value })} required />
        <select value={form.campusId} onChange={(e) => setForm({ ...form, campusId: e.currentTarget.value })}>
          {campuses.map((c) => (
            <option value={c.id}>{campusName(c.id)}</option>
          ))}
        </select>
        <input class="url-in" placeholder="Control URL (optional)" value={form.controlUrl} onInput={(e) => setForm({ ...form, controlUrl: e.currentTarget.value })} />
        <button type="submit" class="primary">
          Create
        </button>
      </form>
    </div>
  );
}
