import { createContext } from 'preact';
import { useContext, useEffect, useState } from 'preact/hooks';
import { THEMES } from '../../shared/themes';
import type { Theme } from '../../shared/types';
import { api } from './api';
import { type Fonts, loadFonts } from './fonts';
import { loadThemeImages } from './render';

export interface Me {
  user: { email: string; name: string | null; role: 'pa' | 'operator' | 'production' | 'admin' };
  themes: string[];
}
export const MeContext = createContext<Me>(null as unknown as Me);
export const useMe = () => useContext(MeContext);
/** Operators are PAs (own messages only) who can also run the CG Macs' control GUI. */
export const canSeeAll = (me: Me) => me.user.role === 'production' || me.user.role === 'admin';

export interface Campus {
  id: string;
  name: string;
  default_theme_id: string;
  sort: number;
  /** email a ProPresenter .probundle with each push (legacy setup) */
  send_probundle?: number;
  recipients: { email: string; name: string | null }[];
}

export function useCampuses(): [Campus[] | null, () => void] {
  const [c, setC] = useState<Campus[] | null>(null);
  const load = () => api<{ campuses: Campus[] }>('/campuses').then((r) => setC(r.campuses));
  useEffect(() => {
    load();
  }, []);
  return [c, load];
}

export interface RenderKit {
  fonts: Fonts;
  theme: Theme;
  imgs: Record<string, HTMLImageElement>;
}

/** Fonts + theme images, ready to render. */
export function useRenderKit(themeId: string): { kit: RenderKit | null; error: string | null } {
  const [kit, setKit] = useState<RenderKit | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    const theme = THEMES[themeId] ?? THEMES.central;
    Promise.all([loadFonts(), loadThemeImages(theme)]).then(
      ([fonts, imgs]) => live && setKit({ fonts, theme, imgs }),
      (e) => live && setError(e.message),
    );
    return () => {
      live = false;
    };
  }, [themeId]);
  return { kit, error };
}

export function ago(iso: string | null | undefined): string {
  if (!iso) return 'never';
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(iso).toLocaleDateString('en-NZ', { day: 'numeric', month: 'short', year: 'numeric' });
}

/** Next Sunday (today if it is Sunday) as YYYY-MM-DD in NZ. */
export function nextSunday(): string {
  const nz = new Date(new Date().toLocaleString('en-US', { timeZone: 'Pacific/Auckland' }));
  nz.setDate(nz.getDate() + ((7 - nz.getDay()) % 7));
  return `${nz.getFullYear()}-${String(nz.getMonth() + 1).padStart(2, '0')}-${String(nz.getDate()).padStart(2, '0')}`;
}

const PREVIEW_KEY = 'notes.previewTheme';
export function getPreviewTheme(): string {
  try {
    return localStorage.getItem(PREVIEW_KEY) || 'central';
  } catch {
    return 'central';
  }
}
export function setPreviewTheme(id: string) {
  try {
    localStorage.setItem(PREVIEW_KEY, id);
  } catch {
    /* ignore */
  }
}
