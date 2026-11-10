// Automatic slide splitting (FORMAT.md "Splitting rules").
import { countLines, type TextStyle } from './layout';
import { applyNoOrphan, NBSP, normalizeRuns } from './markup';
import { parseQuote, parseReference, parseVerses, scriptureBody, type Verse } from './parse';
import { closingFor, reopenFor, scanQuotes } from './quotes';
import type { Block, Measure, Run, Slide } from './types';

export interface SplitContext {
  measure: Measure;
  /** small style + the box width to wrap in (narrowest theme) */
  small: TextStyle & { width: number; maxLines: number };
  big: TextStyle & { width: number };
  /** max body lines for scripture / quote slides (FORMAT: 3) */
  bodyLines?: number;
}

const ELLIPSIS = '\u2026'; // one character: …

interface Piece {
  n: number | null;
  words: string[];
  cont: boolean; // continues a verse split on the previous slide: `35 … `
  cut: boolean; // verse continues on the next slide: ends with `…`
}

function pieceText(p: Piece): string {
  let s = '';
  // Verse numbers stay inline but never end a line on their own: no-break space after the number.
  if (p.n !== null) s += `${p.n}${p.cont ? ' ' : NBSP}`;
  if (p.cont) s += `${ELLIPSIS} `;
  let words = p.words.join(' ');
  // keep the punctuation; a (no-break) space before the … (`surprised, …`, `for Jews …`)
  if (p.cut) words = words + NBSP + ELLIPSIS;
  return s + words;
}

/** Renders a slide body: carried-in quotes reopened after the verse number / `…`, open quotes closed at the end. */
function renderBody(pieces: Piece[], carried: string[], closeOpen: boolean): { text: string; open: string[] } {
  let text = pieces.map(pieceText).join(' ');
  const open = scanQuotes(text, carried);
  if (carried.length) {
    const m = /^(\d{1,3}[ \u00a0])?(\u2026 )?/.exec(text)!;
    text = text.slice(0, m[0].length) + reopenFor(carried) + text.slice(m[0].length);
  }
  if (closeOpen && open.length) text += closingFor(open);
  return { text, open };
}

function lastSpaceToNbsp(text: string): string {
  const i = text.lastIndexOf(' ');
  if (i <= 0 || i >= text.length - 1) return text;
  return text.slice(0, i) + NBSP + text.slice(i + 1);
}

const BREAK_AFTER = /[,;:.!?][”’"')]*$/;

/**
 * Splits a run of verses (or a quote, as one unnumbered "verse") into slide bodies of at most
 * `maxLines` lines. One whole verse per slide; a slide that would hold a single line takes the next
 * verse too (whole if it fits, else split mid-verse). A verse longer than `maxLines` on its own is
 * split mid-verse. This reproduces LIFE's decks (John 4:4-10 -> [4-5] [6] [7] [8] [9] [10]).
 */
export function splitUnits(units: Verse[], maxLines: number, ctx: SplitContext): string[] {
  const st = ctx.small;
  const lines = (text: string) => countLines([{ t: text }], st.width, st, ctx.measure);
  const bodies: string[] = [];
  let carried: string[] = [];
  let cur: Piece[] = [];
  const queue: Piece[] = units
    .filter((u) => u.text.trim() || u.n !== null)
    .map((u) => ({ n: u.n, words: u.text.split(/\s+/).filter(Boolean), cont: false, cut: false }));

  const finalText = (pieces: Piece[], last: boolean) => lastSpaceToNbsp(renderBody(pieces, carried, !last).text);
  const fits = (pieces: Piece[], last: boolean) => lines(finalText(pieces, last)) <= maxLines;
  const close = (last: boolean) => {
    if (!cur.length) return;
    const r = renderBody(cur, carried, !last);
    bodies.push(lastSpaceToNbsp(r.text));
    carried = last ? [] : r.open;
    cur = [];
  };

  while (queue.length) {
    const u = queue[0];
    const isLast = queue.length === 1;
    // One verse per slide; a slide only takes more when it would otherwise hold a single line.
    if (cur.length && lines(finalText(cur, false)) >= 2) {
      close(false);
      continue;
    }
    if (fits([...cur, u], isLast)) {
      cur.push(u);
      queue.shift();
      continue;
    }
    // Mid-verse split: the verse is too long on its own, or the slide holds only one line.
    let k = 0;
    for (let j = u.words.length - 1; j >= 1; j--) {
      if (fits([...cur, { ...u, words: u.words.slice(0, j), cut: true }], false)) {
        k = j;
        break;
      }
    }
    const minKeep = cur.length ? 3 : 1;
    if (k >= minKeep) {
      // prefer breaking after a comma/clause or before "and", if it doesn't leave the slide too empty
      let best = k;
      for (let j = k; j >= Math.max(1, Math.ceil(k * 0.6)); j--) {
        if (BREAK_AFTER.test(u.words[j - 1]) || (j < u.words.length && /^and$/i.test(u.words[j]))) {
          best = j;
          break;
        }
      }
      cur.push({ ...u, words: u.words.slice(0, best), cut: true });
      close(false);
      queue[0] = { n: u.n, words: u.words.slice(best), cont: true, cut: false };
    } else if (cur.length) {
      close(false);
    } else {
      // not even one word fits; give it a slide of its own (flagged as too long later)
      cur.push(u);
      queue.shift();
      close(queue.length === 0);
    }
  }
  close(true);
  return bodies;
}

const boldLineCount = (text: string, ctx: SplitContext) =>
  countLines([{ t: text, b: true }], ctx.small.width, ctx.small, ctx.measure);

export function splitScripture(block: Block, ctx: SplitContext): Slide[] {
  const lines = block.text.split('\n');
  const ref = parseReference(lines[0]);
  const heading = ref ? ref.heading : lines[0].trim();
  const verses = parseVerses(scriptureBody(block.text), ref?.verse ?? null);
  const maxBody = Math.max(1, Math.min(ctx.bodyLines ?? 3, ctx.small.maxLines - boldLineCount(heading, ctx)));
  const bodies = splitUnits(verses, maxBody, ctx);
  if (!bodies.length) bodies.push('');
  return bodies.map((body, i) => ({
    id: `${block.id}-${i + 1}`,
    kind: 'scripture',
    style: 'small',
    runs: normalizeRuns([{ t: heading, b: true }, { t: body ? `\n${body}` : '' }]),
  }));
}

export function splitQuote(block: Block, ctx: SplitContext): Slide[] {
  const q = parseQuote(block.text);
  const authorLines = q.author ? boldLineCount(q.author, ctx) : 0;
  const maxBody = Math.max(1, Math.min(ctx.bodyLines ?? 3, ctx.small.maxLines - authorLines));
  const bodies = splitUnits([{ n: null, text: q.text }], maxBody, ctx);
  return bodies.map((body, i) => ({
    id: `${block.id}-${i + 1}`,
    kind: 'quote',
    style: 'small',
    runs: normalizeRuns([{ t: body }, ...(q.author ? [{ t: `\n${q.author}`, b: true }] : [])]),
  }));
}

/** A point: exactly as typed, all bold; big if it fits one line at the big size. */
export function pointSlide(block: Block, ctx: SplitContext): Slide {
  const text = block.text.replace(/\u00a0/g, ' ');
  const oneLine = !text.includes('\n') && countLines([{ t: text, b: true }], ctx.big.width, ctx.big, ctx.measure) === 1;
  const runs: Run[] = [{ t: text, b: true }];
  return {
    id: `${block.id}-1`,
    kind: 'point',
    style: oneLine ? 'big' : 'small',
    runs: oneLine ? runs : applyNoOrphan(runs),
  };
}

export function buildSlides(blocks: Block[], ctx: SplitContext): Slide[] {
  const out: Slide[] = [];
  for (const b of blocks) {
    if (b.kind === 'scripture') out.push(...splitScripture(b, ctx));
    else if (b.kind === 'quote') out.push(...splitQuote(b, ctx));
    else out.push(pointSlide(b, ctx));
  }
  return out.map(capitaliseStart);
}

/**
 * LIFE rule: every slide starts with a capital letter, even when the text doesn't (a verse that continues
 * a sentence: `2 but whose delight…` -> `2 But whose delight…`). For scripture that's the first letter after
 * the bold reference, past the verse number, `…` and opening quote marks; otherwise the slide's first letter.
 */
export function capitaliseStart(slide: Slide): Slide {
  const text = slide.runs.map((r) => r.t).join('');
  let from = 0;
  if (slide.kind === 'scripture') {
    const nl = text.indexOf('\n');
    if (nl < 0) return slide;
    from = nl + 1;
  }
  const m = /^[\s\u00a0]*(?:\d{1,3}[\s\u00a0]+)?(?:(?:\.\.\.|\u2026)[\s\u00a0]*)?["“‘'(\[«\s\u00a0]*/.exec(text.slice(from))!;
  const at = from + m[0].length;
  const ch = text[at];
  if (!ch || ch.toLocaleUpperCase() === ch || !/\p{Ll}/u.test(ch)) return slide;
  let pos = 0;
  return {
    ...slide,
    runs: slide.runs.map((r) => {
      const start = pos;
      pos += r.t.length;
      if (at < start || at >= pos) return r;
      const i = at - start;
      return { ...r, t: r.t.slice(0, i) + ch.toLocaleUpperCase() + r.t.slice(i + 1) };
    }),
  };
}

/** No-break spaces that are part of the format: after a verse number, and before a `…`. */
export function structuralNbsp(slide: Slide): Slide {
  return {
    ...slide,
    runs: slide.runs.map((r) => {
      let t = r.t.replace(/ (?=\u2026)/g, NBSP);
      if (slide.kind === 'scripture') t = t.replace(/(^|[\s\u00a0])(\d{1,3}) (?=[\p{L}"“‘'])/gu, `$1$2${NBSP}`);
      return { ...r, t };
    }),
  };
}

/** Re-applies the no-orphan NBSP, the format's no-break spaces and the opening capital after a manual edit. */
export function fixOrphans(slide: Slide): Slide {
  slide = structuralNbsp(fixOrphansOnly(capitaliseStart(slide)));
  return slide;
}

function fixOrphansOnly(slide: Slide): Slide {
  if (slide.style === 'big') return { ...slide, runs: slide.runs.map((r) => ({ ...r, t: r.t.replace(/\u00a0/g, ' ') })) };
  const hasAuthor = slide.kind === 'quote' && slide.runs.length > 1 && !!slide.runs[slide.runs.length - 1].b;
  return { ...slide, runs: normalizeRuns(applyNoOrphan(slide.runs, hasAuthor)) };
}
