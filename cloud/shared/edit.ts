// Manual slide edits in the reflow view: split at the cursor, merge with the next slide.
import { markupToRuns, plainText, runsToMarkup } from './markup';
import { fixOrphans } from './split';
import type { Slide } from './types';

function heading(slide: Slide): string | null {
  return slide.kind === 'scripture' && slide.runs[0]?.b ? slide.runs[0].t.split('\n')[0] : null;
}

function author(slide: Slide): string | null {
  const last = slide.runs[slide.runs.length - 1];
  return slide.kind === 'quote' && slide.runs.length > 1 && last.b && last.t.startsWith('\n') ? last.t.slice(1) : null;
}

export function nextSlideId(slides: Slide[], like: string): string {
  const base = like.replace(/-[^-]*$/, '') || 'x';
  const used = new Set(slides.map((s) => s.id));
  for (let n = 1; ; n++) if (!used.has(`${base}-${n}`)) return `${base}-${n}`;
}

const stripTrailing = (s: string) => s.replace(/[\s\u00a0]+$/, '');
const stripLeading = (s: string) => s.replace(/^[\s\u00a0]+/, '');

const COMMON = new Set(
  ('a an and as at be because been but by for from he her his how i if in into is it its may might not of on or our out ' +
    'said says shall she so than that the their them then there these they this those to up was we were what when where which ' +
    'while who whom whose will with would you your all also even yet nor until unless though although after before since ' +
    'about over under through upon').split(' ').filter((w) => w !== 'i'),
);

/** Splits a slide's markup at `pos`. Scripture keeps its heading on both halves and gets `…` /
 *  `<verse> … ` when the cut is mid-verse; quotes keep the author on both and get `…`. */
export function splitSlideAt(slide: Slide, markup: string, pos: number, newId: string): [Slide, Slide] {
  let left = markup.slice(0, pos);
  let right = markup.slice(pos);
  const openBold = (left.match(/\*\*/g) ?? []).length % 2 === 1;
  left = stripTrailing(left);
  right = stripLeading(right);
  if (openBold) {
    left += '**';
    right = '**' + right;
  }
  const head = heading(slide);
  const auth = author(slide);
  if (head && left.includes('\n')) {
    const leftBody = left.slice(left.indexOf('\n') + 1);
    const verseStart = /^\d/.test(right.replace(/^\*\*/, ''));
    if (!verseStart && right) {
      const nums = [...leftBody.matchAll(/(?:^|\s)(\d{1,3})(?=[\s\u00a0])/g)];
      const verse = nums.length ? nums[nums.length - 1][1] : null;
      left = left.replace(/[\s\u00a0]+$/, '') + '\u00a0\u2026';
      right = `${verse ? verse + ' ' : ''}\u2026 ${right}`;
    }
    right = `**${head}**\n${right}`;
  } else if (auth) {
    const authMarkup = `\n**${auth}**`;
    if (!right.startsWith('**') && right !== authMarkup.trim()) {
      left = left.replace(/[\s\u00a0]+$/, '') + '\u00a0\u2026';
      right = `\u2026 ${right}`;
    }
    left += authMarkup;
  }
  const a = fixOrphans({ ...slide, runs: markupToRuns(left) });
  const b = fixOrphans({ ...slide, id: newId, runs: markupToRuns(right) });
  return [a, b];
}

export function mergeSlides(a: Slide, b: Slide): Slide {
  let ma = runsToMarkup(a.runs);
  let mb = runsToMarkup(b.runs);
  const ha = heading(a);
  if (ha && heading(b) === ha) mb = mb.replace(`**${ha}**\n`, '');
  const au = author(a);
  if (au && author(b) === au) ma = ma.slice(0, ma.length - `\n**${au}**`.length);
  ma = stripTrailing(ma.replace(/\u00a0/g, ' '));
  mb = stripLeading(mb.replace(/\u00a0/g, ' '));
  if (/(\.\.\.|\u2026)$/.test(ma) && /^(\d{1,3}[ \u00a0])?(\.\.\.|\u2026) /.test(mb)) {
    ma = ma.replace(/[ \u00a0]?(\.\.\.|\u2026)$/, '');
    mb = mb.replace(/^(\d{1,3}[ \u00a0])?(\.\.\.|\u2026) /, '');
    // undo the slide-start capital the split added (`9 … For Jews` -> `for Jews`), but not on names
    if (!/[.!?]["”’]?$/.test(ma)) mb = mb.replace(/^(["“‘]?)(\p{Lu})(\p{Ll}*)/u, (w, q, c, rest) => {
      const lower = (c + rest).toLowerCase();
      return COMMON.has(lower) || new RegExp(`(^|[^\\p{L}])${lower}(?![\\p{L}])`, 'u').test(ma + ' ' + mb.slice(w.length)) ? q + c.toLowerCase() + rest : w;
    });
  }
  const runs = markupToRuns(`${ma}${ma && mb ? ' ' : ''}${mb}`);
  return fixOrphans({ ...a, style: plainText(runs).includes('\n') ? 'small' : a.style, runs });
}
