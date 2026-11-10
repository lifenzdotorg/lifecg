// Loads the private Neuzeit fonts (served by the Worker at /fonts/<name>.ttf) with FontFace, and
// provides the canvas-backed Measure used for wrapping, splitting and rendering.
import { readFontMetrics } from '../../shared/fontmetrics';
import type { FontMetrics, Measure } from '../../shared/types';

export const FONT_NAMES = ['NeuzeitGro-Reg', 'NeuzeitGro-Bol'] as const;

export interface Fonts {
  measure: Measure;
  metrics: Record<string, FontMetrics>;
}

let loading: Promise<Fonts> | null = null;

export function loadFonts(): Promise<Fonts> {
  if (!loading) loading = doLoad();
  return loading;
}

async function doLoad(): Promise<Fonts> {
  const metrics: Record<string, FontMetrics> = {};
  await Promise.all(
    FONT_NAMES.map(async (name) => {
      const res = await fetch(`/fonts/${name}.ttf`, { credentials: 'same-origin' });
      if (!res.ok) throw new Error(`Font ${name}: ${res.status} ${await res.text()}`);
      const buf = await res.arrayBuffer();
      metrics[name] = readFontMetrics(buf);
      const face = new FontFace(name, buf);
      await face.load();
      document.fonts.add(face);
    }),
  );
  const ctx = document.createElement('canvas').getContext('2d')!;
  const cache = new Map<string, number>();
  const measure: Measure = (text, font, size) => {
    const key = `${font}|${size}|${text}`;
    let w = cache.get(key);
    if (w === undefined) {
      ctx.font = `${size}px "${font}"`;
      w = ctx.measureText(text).width;
      if (cache.size > 50000) cache.clear();
      cache.set(key, w);
    }
    return w;
  };
  return { measure, metrics };
}
