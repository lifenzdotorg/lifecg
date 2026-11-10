import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { api } from './api';
import { AdminPage } from './pages/Admin';
import { EditorPage } from './pages/Editor';
import { MessagesPage } from './pages/Messages';
import { ServicesPage } from './pages/Services';
import { type Me, MeContext } from './state';

function useHashRoute(): string[] {
  const parse = () => (location.hash.replace(/^#\/?/, '') || 'messages').split('/');
  const [route, setRoute] = useState(parse);
  useEffect(() => {
    const on = () => setRoute(parse());
    addEventListener('hashchange', on);
    return () => removeEventListener('hashchange', on);
  }, []);
  return route;
}

function App() {
  const [me, setMe] = useState<Me | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const route = useHashRoute();
  useEffect(() => {
    api<Me>('/me').then(setMe, (e) => setErr(e.message));
  }, []);

  if (err) return <div class="boot">Can’t sign you in: {err}</div>;
  if (!me) return <div class="boot">Loading…</div>;
  const [page, id] = route;
  const nav = (p: string, label: string) => (
    <a href={`#/${p}`} class={page === p ? 'active' : ''}>
      {label}
    </a>
  );
  return (
    <MeContext.Provider value={me}>
      <header class="top">
        <a class="brand" href="#/messages">
          <span class="mark">LIFE</span> Speaker Notes
        </a>
        <nav>
          {nav('messages', 'Messages')}
          {nav('services', 'Services')}
          {me.user.role === 'admin' && nav('admin', 'Admin')}
        </nav>
        <div class="who" title={me.user.email}>
          {me.user.email} <span class={`role role-${me.user.role}`}>{me.user.role === 'pa' ? 'PA' : me.user.role}</span>
        </div>
      </header>
      <main>
        {page === 'messages' && !id && <MessagesPage />}
        {page === 'messages' && id && <EditorPage key={id} id={id} />}
        {page === 'services' && <ServicesPage />}
        {page === 'admin' && me.user.role === 'admin' && <AdminPage />}
      </main>
    </MeContext.Provider>
  );
}

render(<App />, document.getElementById('app')!);

// Local dev only: expose the renderer for visual checks against real ProPresenter exports.
if (location.hostname === 'localhost') {
  Promise.all([import('./render'), import('./fonts'), import('../../shared/themes')]).then(([r, f, t]) => {
    (window as unknown as Record<string, unknown>).__notes = { ...r, ...f, ...t };
  });
}
