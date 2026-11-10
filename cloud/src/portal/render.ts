// Canvas renderer for notes slides, implementing the theme semantics in FORMAT.md:
// layers in order; text white with an outline drawn under the fill (lineWidth = 2*size*strokePercent/100,
// strokeText then fillText, so only the outer half shows);
// tracking via letterSpacing; one shadow for the whole text (angle 270 = down, shadowBlur = blur);
// lines laid out by shared/layout (lineHeight multiple, valign within rect).
import { layoutText, segWidth } from '../../shared/layout';
import type { Slide, Theme } from '../../shared/types';
import type { Fonts } from './fonts';

/** What sits behind the lower third in previews (stands in for the camera feed). */
export const PREVIEW_BACKDROP = '#4a4f57';

const images = new Map<string, Promise<HTMLImageElement>>();
export function loadImage(src: string): Promise<HTMLImageElement> {
  let p = images.get(src);
  if (!p) {
    p = new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error(`image ${src}`));
      img.src = src;
    });
    images.set(src, p);
  }
  return p;
}

export async function loadThemeImages(theme: Theme): Promise<Record<string, HTMLImageElement>> {
  const out: Record<string, HTMLImageElement> = {};
  for (const l of theme.layers) if (l.type === 'image' && l.src) out[l.src] = await loadImage(`/themes/${theme.id}/${l.src}`);
  return out;
}

export interface RenderOptions {
  scale: number; // output px per canvas point
  crop?: { y: number; h: number }; // vertical band of the 1920x1080 frame
  backdrop?: string | null;
}

let scratch: HTMLCanvasElement | null = null;
const hasLetterSpacing = typeof CanvasRenderingContext2D !== 'undefined' && 'letterSpacing' in CanvasRenderingContext2D.prototype;

export function renderSlide(
  canvas: HTMLCanvasElement,
  theme: Theme,
  slide: Slide,
  fonts: Fonts,
  imgs: Record<string, HTMLImageElement>,
  opts: RenderOptions,
) {
  const { scale } = opts;
  const crop = opts.crop ?? { y: 0, h: theme.canvas[1] };
  const W = Math.round(theme.canvas[0] * scale);
  const H = Math.round(crop.h * scale);
  if (canvas.width !== W) canvas.width = W;
  if (canvas.height !== H) canvas.height = H;
  const ctx = canvas.getContext('2d')!;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, W, H);
  if (opts.backdrop !== null) {
    ctx.fillStyle = opts.backdrop ?? PREVIEW_BACKDROP;
    ctx.fillRect(0, 0, W, H);
  }
  ctx.setTransform(scale, 0, 0, scale, 0, -crop.y * scale);

  for (const l of theme.layers) {
    const [x, y, w, h] = l.rect;
    if (l.type === 'image' && l.src && imgs[l.src]) ctx.drawImage(imgs[l.src], x, y, w, h);
    else if (l.type === 'rect') {
      ctx.globalAlpha = l.opacity ?? 1;
      ctx.fillStyle = l.color ?? '#000';
      ctx.fillRect(x, y, w, h);
      ctx.globalAlpha = 1;
    }
  }

  // Text goes to a scratch canvas first so the stroke and fill cast a single shadow.
  scratch ??= document.createElement('canvas');
  if (scratch.width !== W) scratch.width = W;
  if (scratch.height !== H) scratch.height = H;
  const tctx = scratch.getContext('2d')!;
  tctx.setTransform(1, 0, 0, 1, 0, 0);
  tctx.clearRect(0, 0, W, H);
  tctx.setTransform(scale, 0, 0, scale, 0, -crop.y * scale);

  const style = theme.styles[slide.style] ?? theme.styles.small;
  const t = theme.text;
  const layout = layoutText(slide.runs, style, fonts.measure, fonts.metrics[style.regularFont]);
  tctx.textBaseline = 'alphabetic';
  tctx.lineJoin = 'round';
  tctx.lineWidth = (2 * style.size * t.strokePercent) / 100;
  tctx.strokeStyle = t.strokeColor;
  tctx.fillStyle = t.color;
  for (const line of layout.lines) {
    let x = line.x;
    for (const seg of line.segs) {
      const font = seg.b ? style.boldFont : style.regularFont;
      tctx.font = `${style.size}px "${font}"`;
      if (hasLetterSpacing) {
        (tctx as unknown as { letterSpacing: string }).letterSpacing = `${style.tracking}px`;
        if (t.strokePercent) tctx.strokeText(seg.t, x, line.baseline);
        tctx.fillText(seg.t, x, line.baseline);
      } else {
        // no canvas letterSpacing (older Safari): place characters one by one
        const chars = [...seg.t];
        let prefix = '';
        chars.forEach((ch, i) => {
          const cx = x + fonts.measure(prefix, font, style.size) + style.tracking * i;
          if (t.strokePercent) tctx.strokeText(ch, cx, line.baseline);
          tctx.fillText(ch, cx, line.baseline);
          prefix += ch;
        });
      }
      x += segWidth(seg.t, seg.b, style, fonts.measure);
    }
  }

  const sh = t.shadow;
  const rad = (sh.angle * Math.PI) / 180;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.save();
  ctx.shadowColor = sh.color;
  // canvas shadows ignore the transform, so scale them by hand; y is flipped (Cocoa angles, y up)
  ctx.shadowOffsetX = sh.offset * Math.cos(rad) * scale;
  ctx.shadowOffsetY = -sh.offset * Math.sin(rad) * scale;
  ctx.shadowBlur = sh.blur * scale;
  ctx.drawImage(scratch, 0, 0);
  ctx.restore();
  return layout;
}
