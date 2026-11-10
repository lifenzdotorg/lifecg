// Line wrapping and text-box layout shared by the splitter (line counts) and the canvas renderer.
//
// Semantics: FORMAT.md "Slide" + "Text layout" (calibrated against ProPresenter 7 exports):
//  * `\n` is a hard break; everything else wraps at U+0020 spaces. U+00A0 never breaks.
//  * Tracking = extra px after every character (Cocoa NSKern / canvas letterSpacing), spaces included;
//    the tracking after a line's last character is not counted when testing whether the line fits.
//  * TextKit's 5 pt line padding: wrap width = rect.w - 10, lines start at rect.x + 5.
//  * Metrics are the style's regular font hhea A (ascender), D (|descender|), G (lineGap) at `size`.
//    Pitch P = (A + D + G) x lineHeight; baseline_i = top + i*P + A;
//    block height H = (n - 1)*P + A + D + G + 5; top from valign within rect.

import type { FontMetrics, Measure, Run, ThemeStyle } from './types';

export interface TextStyle {
  regularFont: string;
  boldFont: string;
  size: number;
  tracking: number;
}

export interface Seg {
  t: string;
  b: boolean;
}

export interface Line {
  segs: Seg[];
  width: number;
}

const charCount = (s: string) => [...s].length;

export function segWidth(text: string, bold: boolean, style: TextStyle, measure: Measure): number {
  if (!text) return 0;
  return measure(text, bold ? style.boldFont : style.regularFont, style.size) + style.tracking * charCount(text);
}

type Item = { kind: 'word'; segs: Seg[] } | { kind: 'space'; b: boolean };

function paragraphs(runs: Run[]): Item[][] {
  const paras: Item[][] = [[]];
  let word: Seg[] | null = null;
  const flush = () => {
    if (word) paras[paras.length - 1].push({ kind: 'word', segs: word });
    word = null;
  };
  for (const run of runs) {
    const b = !!run.b;
    for (const piece of run.t.split(/(\n| )/)) {
      if (piece === '') continue;
      if (piece === '\n') {
        flush();
        paras.push([]);
      } else if (piece === ' ') {
        flush();
        paras[paras.length - 1].push({ kind: 'space', b });
      } else {
        if (!word) word = [];
        word.push({ t: piece, b });
      }
    }
  }
  flush();
  return paras;
}

function pushSeg(segs: Seg[], s: Seg) {
  const last = segs[segs.length - 1];
  if (last && last.b === s.b) last.t += s.t;
  else segs.push({ ...s });
}

/** Greedy word wrap of `runs` into lines no wider than `maxWidth` (a single over-long word overflows). */
export function wrapRuns(runs: Run[], maxWidth: number, style: TextStyle, measure: Measure): Line[] {
  const lines: Line[] = [];
  for (const items of paragraphs(runs)) {
    let segs: Seg[] = [];
    let width = 0;
    let hasWord = false;
    let pending: Seg[] = []; // spaces waiting for the next word
    let pendingW = 0;
    for (const it of items) {
      if (it.kind === 'space') {
        pending.push({ t: ' ', b: it.b });
        pendingW += segWidth(' ', it.b, style, measure);
        continue;
      }
      const ww = it.segs.reduce((a, s) => a + segWidth(s.t, s.b, style, measure), 0);
      // the tracking after a line's last character doesn't count toward the fit (matches ProPresenter's wraps)
      if (hasWord && width + pendingW + ww - style.tracking > maxWidth + 0.01) {
        lines.push({ segs, width });
        segs = [];
        width = 0;
        pending = [];
        pendingW = 0;
      }
      for (const s of pending) pushSeg(segs, s);
      for (const s of it.segs) pushSeg(segs, s);
      width += pendingW + ww;
      pending = [];
      pendingW = 0;
      hasWord = true;
    }
    lines.push({ segs, width });
  }
  return lines;
}

export function countLines(runs: Run[], maxWidth: number, style: TextStyle, measure: Measure): number {
  return wrapRuns(runs, maxWidth, style, measure).length;
}

/** TextKit line fragment padding on each side of the text box (FORMAT.md "Text layout"). */
export const LINE_PADDING = 5;

/** Width lines wrap in for a text box of width `rectWidth`. */
export const wrapWidth = (rectWidth: number) => rectWidth - 2 * LINE_PADDING;

export interface PlacedLine extends Line {
  x: number;
  baseline: number;
}

export interface TextLayout {
  lines: PlacedLine[];
  lineAdvance: number;
  overflow: boolean; // more lines than style.maxLines
}

/** Positions the lines of a slide inside the style's rect (canvas coordinates, origin top-left). */
export function layoutText(runs: Run[], style: ThemeStyle, measure: Measure, metrics: FontMetrics): TextLayout {
  const [rx, ry, rw, rh] = style.rect;
  const width = wrapWidth(rw);
  const lines = wrapRuns(runs, width, style, measure);
  const scale = style.size / metrics.unitsPerEm;
  const A = metrics.ascender * scale;
  const D = -metrics.descender * scale;
  const G = metrics.lineGap * scale;
  const pitch = (A + D + G) * style.lineHeight;
  const blockH = (Math.max(1, lines.length) - 1) * pitch + A + D + G + LINE_PADDING;
  let top = ry;
  if (style.valign === 'bottom') top = ry + rh - blockH;
  else if (style.valign === 'middle') top = ry + (rh - blockH) / 2;
  const left = rx + LINE_PADDING;
  const placed = lines.map((l, i) => {
    let x = left;
    if (style.align === 'center') x = left + (width - l.width) / 2;
    else if (style.align === 'right') x = left + width - l.width;
    return { ...l, x, baseline: top + i * pitch + A };
  });
  return { lines: placed, lineAdvance: pitch, overflow: lines.length > style.maxLines };
}
