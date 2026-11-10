import central from '../../notes-themes/central/theme.json';
import west from '../../notes-themes/west/theme.json';
import ns from '../../notes-themes/ns/theme.json';
import chapel from '../../notes-themes/chapel/theme.json';
import east from '../../notes-themes/east/theme.json';
import eastBg from '../../notes-themes/east-bg/theme.json';
import type { Theme, ThemeStyle } from './types';

export const THEMES: Record<string, Theme> = {
  central: central as unknown as Theme,
  west: west as unknown as Theme,
  ns: ns as unknown as Theme,
  east: east as unknown as Theme,
  'east-bg': eastBg as unknown as Theme,
  chapel: chapel as unknown as Theme,
};
export const THEME_IDS = Object.keys(THEMES);

/** Text style the splitter uses: the narrowest box of that style across all themes, so slides fit everywhere. */
export function splitStyle(style: 'small' | 'big'): ThemeStyle {
  const all = Object.values(THEMES).map((t) => t.styles[style]);
  return all.reduce((a, b) => (b.rect[2] < a.rect[2] ? b : a));
}

/** Region of the 1920x1080 frame worth showing in a cropped preview: the text boxes plus padding, full width. */
export function previewCrop(theme: Theme): { y: number; h: number } {
  const rects = [theme.styles.small.rect, theme.styles.big.rect];
  const top = Math.max(0, Math.min(...rects.map((r) => r[1])) - 40);
  const bottom = Math.min(theme.canvas[1], Math.max(...rects.map((r) => r[1] + r[3])) + 40);
  return { y: Math.floor(top), h: Math.ceil(bottom - top) };
}
