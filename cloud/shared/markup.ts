// Slide text <-> editable markup: `**bold**` marks bold runs, everything else is regular.
import type { Run } from './types';

export const NBSP = '\u00a0';

export function plainText(runs: Run[]): string {
  return runs.map((r) => r.t).join('');
}

export function normalizeRuns(runs: Run[]): Run[] {
  const out: Run[] = [];
  for (const r of runs) {
    if (!r.t) continue;
    const last = out[out.length - 1];
    if (last && !!last.b === !!r.b) last.t += r.t;
    else out.push(r.b ? { t: r.t, b: true } : { t: r.t });
  }
  return out;
}

export function runsToMarkup(runs: Run[]): string {
  return normalizeRuns(runs)
    .map((r) => {
      if (!r.b) return r.t;
      // keep newlines outside the markers so the textarea reads naturally
      const m = /^(\n*)([\s\S]*?)(\n*)$/.exec(r.t)!;
      return m[2] ? `${m[1]}**${m[2]}**${m[3]}` : r.t;
    })
    .join('');
}

export function markupToRuns(markup: string): Run[] {
  const parts = markup.split('**');
  return normalizeRuns(parts.map((t, i) => (i % 2 === 1 ? { t, b: true } : { t })));
}

/** Puts a no-break space between the last two words of the slide body (the last line, or the
 *  line before it when `skipLastLine`, e.g. a quote's author line) and turns any other NBSP back into a space. */
export function applyNoOrphan(runs: Run[], skipLastLine = false): Run[] {
  const text = plainText(runs).replace(/\u00a0/g, ' ');
  let end = text.length;
  if (skipLastLine) {
    const nl = text.lastIndexOf('\n');
    if (nl > 0) end = nl;
  }
  // A closing `…` isn't a word: keep the last two words before it together.
  const ell = /[ \u00a0]\u2026["”’')]*$/.exec(text.slice(0, end));
  if (ell) end = ell.index + 1;
  let idx = -1;
  for (let i = end - 2; i > 0; i--) {
    if (text[i] === '\n') break;
    if (text[i] === ' ' && !/\s/.test(text[i - 1]) && !/\s/.test(text[i + 1])) {
      idx = i;
      break;
    }
  }
  let pos = 0;
  return runs.map((r) => {
    let t = r.t.replace(/\u00a0/g, ' ');
    if (idx >= pos && idx < pos + t.length) t = t.slice(0, idx - pos) + NBSP + t.slice(idx - pos + 1);
    pos += r.t.length;
    return r.b ? { t, b: true } : { t };
  });
}
