import { parseReference } from './parse';

// Turning a PA's PDF or Word document into text for the notes box.
//
// Speaker notes come as full documents in which the on-screen content is highlighted (yellow
// scripture, green points, …). Both readers produce paragraphs tagged with their highlight colour;
// `paragraphsToSource` keeps the colours the PA picks and joins each run of same-coloured lines into
// one item (a psalm's poetry lines stay together), separating items with a blank line.

export interface DocParagraph {
  text: string;
  /** just the highlighted part of the line (a point is often highlighted inside a longer sentence) */
  highlightedText?: string;
  /** colour name ("yellow", "green", …) when most of the paragraph is highlighted */
  highlight: string | null;
  bold: boolean;
  /** a visible gap (spacing / empty line) before this paragraph */
  gapBefore: boolean;
  /** this line continues the previous one (the PDF wrapped it): join with a space, not a line break */
  wrapped?: boolean;
}

export interface HighlightSummary {
  colour: string;
  count: number;
  sample: string;
}

export function highlightSummary(paras: DocParagraph[]): HighlightSummary[] {
  const by = new Map<string, HighlightSummary>();
  for (const p of paras) {
    if (!p.highlight || !p.text.trim()) continue;
    const s = by.get(p.highlight) ?? { colour: p.highlight, count: 0, sample: p.text.trim().slice(0, 60) };
    s.count++;
    by.set(p.highlight, s);
  }
  return [...by.values()].sort((a, b) => b.count - a.count);
}

/**
 * `colours` null = everything (no highlight filtering). With colours, only those paragraphs are kept;
 * consecutive kept paragraphs of the same colour become one item unless the document shows a gap
 * and the next one starts a new heading or number sequence is broken (handled later by the parser).
 */
export function paragraphsToSource(paras: DocParagraph[], colours: string[] | null): string {
  const items: string[][] = [];
  let prev: DocParagraph | null = null;
  for (const p of paras) {
    const text = cleanLine(colours === null ? p.text : (p.highlightedText ?? p.text));
    const keep = colours === null ? true : !!p.highlight && colours.includes(p.highlight);
    if (!keep || !text) {
      prev = null;
      continue;
    }
    // Lines of a scripture (poetry lines, verses) stay together; other highlighted lines (points) are
    // separate items unless the PDF just wrapped them.
    const runIsScripture = () => {
      const first = items[items.length - 1]?.[0] ?? '';
      return !!parseReference(first) || /^\d{1,3}\s/.test(first);
    };
    const sameRun =
      prev !== null &&
      (colours === null ? !p.gapBefore : prev.highlight === p.highlight) &&
      (p.wrapped || runIsScripture() || colours === null);
    if (sameRun && p.wrapped) items[items.length - 1].push(items[items.length - 1].pop() + ' ' + text);
    else if (sameRun) items[items.length - 1].push(text);
    else items.push([text]);
    prev = p;
  }
  return items.map((lines) => lines.join('\n')).join('\n\n');
}

export function cleanLine(s: string): string {
  return s
    .replace(/[­​﻿]/g, '')
    .replace(/[\t  -  ]+/g, ' ')
    .replace(/^[\s•●▪◦‣·-]+(?=\S)/, (m) => (/[•●▪◦‣·]/.test(m) ? '' : m.trimStart()))
    .replace(/ {2,}/g, ' ')
    .trim();
}

/** Nearest named highlight colour for an RGB fill (0–255), or null for white/black/greys. */
export function colourName(r: number, g: number, b: number): string | null {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  if (max - min < 40) return null; // white, black, greys (page backgrounds, rules)
  const named: [string, number, number, number][] = [
    ['yellow', 255, 255, 0],
    ['green', 0, 255, 0],
    ['cyan', 0, 255, 255],
    ['magenta', 255, 0, 255],
    ['blue', 0, 0, 255],
    ['red', 255, 0, 0],
    ['dark yellow', 128, 128, 0],
    ['dark green', 0, 128, 0],
    ['teal', 0, 128, 128],
    ['dark blue', 0, 0, 128],
    ['dark red', 128, 0, 0],
    ['violet', 128, 0, 128],
    ['orange', 255, 165, 0],
    ['pink', 255, 192, 203],
  ];
  let best = named[0];
  let bestD = Infinity;
  for (const n of named) {
    const d = (n[1] - r) ** 2 + (n[2] - g) ** 2 + (n[3] - b) ** 2;
    if (d < bestD) {
      bestD = d;
      best = n;
    }
  }
  return best[0];
}

// ───────────────────────── PDF (pdf.js) ─────────────────────────

/* The bits of pdf.js we use (typed loosely so the module can be loaded lazily in the browser and from
   `pdfjs-dist/legacy` in tests). */
interface PdfTextItem {
  str: string;
  transform: number[];
  width: number;
  height: number;
  hasEOL?: boolean;
}
interface PdfPage {
  getTextContent(): Promise<{ items: (PdfTextItem | { type: string })[] }>;
  getOperatorList(): Promise<{ fnArray: number[]; argsArray: unknown[] }>;
}
export interface PdfJs {
  getDocument(src: { data: Uint8Array; isEvalSupported?: boolean; disableFontFace?: boolean }): { promise: Promise<{ numPages: number; getPage(n: number): Promise<PdfPage> }> };
  OPS: Record<string, number>;
}

interface Rect {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  colour: string;
}

type M = [number, number, number, number, number, number];
const mul = (m: M, n: M): M => [
  m[0] * n[0] + m[2] * n[1],
  m[1] * n[0] + m[3] * n[1],
  m[0] * n[2] + m[2] * n[3],
  m[1] * n[2] + m[3] * n[3],
  m[0] * n[4] + m[2] * n[5] + m[4],
  m[1] * n[4] + m[3] * n[5] + m[5],
];
const apply = (m: M, x: number, y: number): [number, number] => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];

/** Filled, coloured rectangles on a page (Word and Pages draw highlights this way). */
async function highlightRects(page: PdfPage, OPS: Record<string, number>): Promise<Rect[]> {
  const { fnArray, argsArray } = await page.getOperatorList();
  const rects: Rect[] = [];
  let ctm: M = [1, 0, 0, 1, 0, 0];
  const stack: { ctm: M; fill: number[] }[] = [];
  let fill: number[] = [0, 0, 0];
  let pending: Rect[] = [];
  const rgb = (a: unknown): number[] => {
    const v = Object.values(a as Record<string, number>).map(Number);
    return v.length >= 3 ? v.slice(0, 3) : [v[0] ?? 0, v[0] ?? 0, v[0] ?? 0];
  };
  for (let i = 0; i < fnArray.length; i++) {
    const fn = fnArray[i];
    const args = argsArray[i] as unknown[];
    if (fn === OPS.save) stack.push({ ctm, fill });
    else if (fn === OPS.restore) ({ ctm, fill } = stack.pop() ?? { ctm, fill });
    else if (fn === OPS.transform) ctm = mul(ctm, args as M);
    else if (fn === OPS.setFillRGBColor) {
      const a = args[0];
      fill = typeof a === 'string' && a.startsWith('#') ? [1, 3, 5].map((k) => parseInt(a.slice(k, k + 2), 16)) : rgb(args.length >= 3 ? args : a);
      if (fill.every((v) => v <= 1) && fill.some((v) => v > 0 && v < 1)) fill = fill.map((v) => v * 255);
    } else if (fn === OPS.setFillGray) fill = [Number(args[0]) * 255, Number(args[0]) * 255, Number(args[0]) * 255];
    else if (fn === OPS.constructPath) {
      const [ops, coords] = args as [number[], number[]];
      let k = 0;
      pending = [];
      for (const op of ops) {
        if (op === OPS.rectangle) {
          const [x, y, w, h] = coords.slice(k, k + 4);
          const [ax, ay] = apply(ctm, x, y);
          const [bx, by] = apply(ctm, x + w, y + h);
          const colour = colourName(fill[0], fill[1], fill[2]);
          if (colour) pending.push({ x0: Math.min(ax, bx), y0: Math.min(ay, by), x1: Math.max(ax, bx), y1: Math.max(ay, by), colour });
          k += 4;
        } else if (op === OPS.moveTo || op === OPS.lineTo) k += 2;
        else if (op === OPS.curveTo) k += 6;
        else if (op === OPS.curveTo2 || op === OPS.curveTo3) k += 4;
      }
    } else if (fn === OPS.fill || fn === OPS.eoFill) {
      // highlights are at least a line tall; thin rectangles are rules and underlines
      rects.push(...pending.filter((r) => r.y1 - r.y0 > 4 && r.x1 - r.x0 > 4));
      pending = [];
    } else if (fn === OPS.endPath || fn === OPS.stroke) pending = [];
  }
  return rects;
}

interface Line {
  y: number;
  size: number;
  parts: { x: number; x1: number; str: string; size: number; hl: string | null }[];
}

/** Reads a PDF into paragraphs: lines by position, paragraph gaps by spacing, highlights by colour. */
export async function pdfParagraphs(pdfjs: PdfJs, data: Uint8Array): Promise<DocParagraph[]> {
  const doc = await pdfjs.getDocument({ data, isEvalSupported: false, disableFontFace: true }).promise;
  const out: DocParagraph[] = [];
  for (let n = 1; n <= doc.numPages; n++) {
    const page = await doc.getPage(n);
    const [content, rects] = await Promise.all([page.getTextContent(), highlightRects(page, pdfjs.OPS)]);
    const lines: Line[] = [];
    for (const it of content.items as PdfTextItem[]) {
      if (typeof it.str !== 'string' || !it.str) continue;
      const [, , , d, x, y] = it.transform;
      const size = Math.abs(d) || it.height || 10;
      const cx = x + (it.width || 0) / 2;
      const cy = y + size * 0.3;
      const hl = it.str.trim() ? (rects.find((r) => cx >= r.x0 && cx <= r.x1 && cy >= r.y0 && cy <= r.y1)?.colour ?? null) : null;
      // same line: baselines within 40% of the larger size (superscript verse numbers sit a little higher)
      let line = lines.find((l) => Math.abs(l.y - y) < Math.max(l.size, size) * 0.4);
      if (!line) lines.push((line = { y, size, parts: [] }));
      if (size > line.size) {
        line.size = size;
        line.y = y;
      }
      line.parts.push({ x, x1: x + (it.width || 0), str: it.str, size, hl });
    }
    lines.sort((a, b) => b.y - a.y);
    const right = (l: Line) => Math.max(...l.parts.map((p) => p.x1));
    const pageRight = Math.max(0, ...lines.map(right));
    let prevRight = 0;
    let prevY: number | null = null;
    let prevSize = 12;
    for (const l of lines) {
      l.parts.sort((a, b) => a.x - b.x);
      let text = '';
      let hlText = '';
      let last: (typeof l.parts)[number] | null = null;
      const hlChars = new Map<string, number>();
      let chars = 0;
      const isSup = (q: (typeof l.parts)[number]) => /^\d{1,3}$/.test(q.str.trim()) && q.size < l.size * 0.85;
      for (const p of l.parts) {
        let sep = '';
        if (last) {
          const gap = p.x - last.x1;
          // a superscript verse number is followed by a space, but its digits ("1","6") stay together
          const afterVerseNo = isSup(last) && !(isSup(p) && gap < l.size * 0.12);
          if ((gap > l.size * 0.12 || afterVerseNo) && !/\s$/.test(text) && !/^\s/.test(p.str)) sep = ' ';
        }
        text += sep + p.str;
        if (p.hl || (isSup(p) && l.parts.some((q) => q.hl))) hlText += (hlText ? sep : '') + p.str;
        else if (hlText && !p.str.trim() && !/\s$/.test(hlText)) hlText += ' ';
        const c = p.str.replace(/\s/g, '').length;
        chars += c;
        if (p.hl) hlChars.set(p.hl, (hlChars.get(p.hl) ?? 0) + c);
        last = p;
      }
      // a leading superscript verse number glued to the word: "1Blessed" -> "1 Blessed"
      const first = l.parts[0];
      if (first && /^\d{1,3}$/.test(first.str.trim()) && first.size < l.size * 0.85 && l.parts.length > 1) {
        text = text.replace(/^(\s*\d{1,3})(?=\S)/, '$1 ');
      }
      // the line's colour: the one covering most of its highlighted characters
      let highlight: string | null = null;
      let most = 0;
      for (const [k, v] of hlChars) if (v > most && v >= Math.min(3, chars)) [highlight, most] = [k, v];
      const gapBefore = prevY === null || prevY - l.y > Math.max(prevSize, l.size) * 1.55;
      // the previous line ran to the right margin, so this one is its continuation
      const wrapped = !gapBefore && prevRight > pageRight * 0.85;
      out.push({ text, highlightedText: highlight ? hlText : undefined, highlight, bold: false, gapBefore, wrapped });
      prevRight = right(l);
      prevY = l.y;
      prevSize = l.size;
    }
  }
  return out;
}

// ───────────────────────── Word (.docx) ─────────────────────────

const WORD_HIGHLIGHTS: Record<string, string> = {
  yellow: 'yellow', green: 'green', cyan: 'cyan', magenta: 'magenta', blue: 'blue', red: 'red',
  darkYellow: 'dark yellow', darkGreen: 'dark green', darkCyan: 'teal', darkBlue: 'dark blue', darkRed: 'dark red',
  darkMagenta: 'violet', lightGray: '', darkGray: '', black: '', white: '',
};

/** Minimal DOM interface so the reader runs with the browser's DOMParser or a test parser. */
export interface XmlParser {
  parseFromString(xml: string, type: 'application/xml'): Document;
}

/** Reads `word/document.xml` (already unzipped) into paragraphs, with highlight and shading colours. */
export function docxParagraphs(documentXml: string, parser: XmlParser): DocParagraph[] {
  const doc = parser.parseFromString(documentXml, 'application/xml');
  const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const out: DocParagraph[] = [];
  const paras = doc.getElementsByTagNameNS(W, 'p');
  let prevAfter = 0;
  for (let i = 0; i < paras.length; i++) {
    const p = paras[i];
    let text = '';
    let hlText = '';
    const hlChars = new Map<string, number>();
    let chars = 0;
    let boldChars = 0;
    const runs = p.getElementsByTagNameNS(W, 'r');
    for (let j = 0; j < runs.length; j++) {
      const r = runs[j];
      const rPr = r.getElementsByTagNameNS(W, 'rPr')[0];
      let hl: string | null = null;
      let sup = false;
      let bold = false;
      if (rPr) {
        const h = rPr.getElementsByTagNameNS(W, 'highlight')[0]?.getAttributeNS(W, 'val');
        if (h && WORD_HIGHLIGHTS[h]) hl = WORD_HIGHLIGHTS[h];
        const shd = rPr.getElementsByTagNameNS(W, 'shd')[0]?.getAttributeNS(W, 'fill');
        if (!hl && shd && /^[0-9a-f]{6}$/i.test(shd)) hl = colourName(parseInt(shd.slice(0, 2), 16), parseInt(shd.slice(2, 4), 16), parseInt(shd.slice(4, 6), 16));
        sup = rPr.getElementsByTagNameNS(W, 'vertAlign')[0]?.getAttributeNS(W, 'val') === 'superscript';
        const b = rPr.getElementsByTagNameNS(W, 'b')[0];
        bold = !!b && !['0', 'false'].includes(b.getAttributeNS(W, 'val') ?? '');
      }
      let t = '';
      for (const node of Array.from(r.childNodes)) {
        const el = node as Element;
        if (el.localName === 't') t += el.textContent ?? '';
        else if (el.localName === 'tab') t += ' ';
        else if (el.localName === 'br' || el.localName === 'cr') t += '\n';
      }
      if (!t) continue;
      if (sup && /^\s*\d{1,3}\s*$/.test(t)) t = t.trim() + ' '; // superscript verse number
      text += t;
      if (hl || sup) hlText += t;
      const c = t.replace(/\s/g, '').length;
      chars += c;
      if (hl) hlChars.set(hl, (hlChars.get(hl) ?? 0) + c);
      if (bold) boldChars += c;
    }
    const spacing = p.getElementsByTagNameNS(W, 'spacing')[0];
    const before = Number(spacing?.getAttributeNS(W, 'before') ?? 0);
    let highlight: string | null = null;
    let most = 0;
    for (const [k, v] of hlChars) if (v > most && v >= Math.min(3, chars)) [highlight, most] = [k, v];
    const hlLines = hlText.split('\n');
    // A soft line break inside a paragraph is a poetry line: keep it as its own line.
    for (const [k, line] of text.split('\n').entries()) {
      out.push({ text: line, highlightedText: highlight ? (hlLines[k] ?? '') : undefined, highlight, bold: chars > 0 && boldChars > chars * 0.6, gapBefore: k === 0 && (before + prevAfter > 0 || !text.trim()) });
    }
    prevAfter = Number(spacing?.getAttributeNS(W, 'after') ?? 160);
  }
  return out;
}
