// Per-slide checks shown as warnings (never auto-changed).
import { plainText } from './markup';
import type { Slide } from './types';

export interface Warning {
  code: 'lines' | 'spelling' | 'start' | 'empty' | 'translation';
  message: string;
}

const OUR = /\b(dis)?(honor|favor|color|behavior|neighbor|labor|savior|harbor|rumor|endeavor|splendor|fervor|valor|vigor|armor|odor|humor)(s|ed|ing|able|ably|ite|ites|ful|hood)?\b/gi;
const RE_ = /\b(center|theater|fiber|meter|somber|luster)(s|ed|ing)?\b/gi;
const IZE = /\b(real|recogn|bapt|apolog|organ|emphas|critic|minim|maxim|priorit|agon|author|evangel|memor|summar|util|symbol|character|sympath|special|familiar|civil|glamor|harmon|jeopard|legal|mobil|neutral|normal|optim|patron|penal|personal|standard|subsid|terror|tranquil|visual|vocal)iz(e|ed|es|ing|ation|ations)\b/gi;
const OTHER: [RegExp, string][] = [
  [/\bjudgment(s)?\b/gi, 'judgement'],
  [/\bfulfill(s|ment)?\b/gi, 'fulfil'],
  [/\btraveled\b|\btraveling\b|\btraveler(s)?\b/gi, 'travell-'],
  [/\bgray\b/gi, 'grey'],
  [/\bcatalog(s)?\b/gi, 'catalogue'],
  [/\bdefense\b/gi, 'defence'],
  [/\boffense\b/gi, 'offence'],
];

function keepCase(src: string, repl: string) {
  return src[0] === src[0].toUpperCase() ? repl[0].toUpperCase() + repl.slice(1) : repl;
}

export function americanSpellings(text: string): string[] {
  const found = new Set<string>();
  for (const m of text.matchAll(OUR)) found.add(`${m[0]} → ${m[0].replace(/or(?=[a-z]*$)/i, (o) => (o === 'OR' ? 'OUR' : 'our'))}`);
  for (const m of text.matchAll(RE_)) found.add(`${m[0]} → ${m[0].replace(/er(s|ed|ing)?$/i, (_e, suf?: string) => (suf === 'ed' ? 'red' : suf === 'ing' ? 'ring' : suf === 's' ? 'res' : 're'))}`);
  for (const m of text.matchAll(IZE)) found.add(`${m[0]} → ${m[0].replace(/iz(?=(e|ed|es|ing|ation|ations)$)/i, 'is')}`);
  for (const [re, fix] of OTHER) for (const m of text.matchAll(re)) found.add(`${m[0]} → ${keepCase(m[0], fix)}`);
  return [...found];
}

/** `lineCount` comes from laying the slide out in the preview theme (real fonts). */
export function slideWarnings(slide: Slide, lineCount: number, maxLines: number): Warning[] {
  const w: Warning[] = [];
  const text = plainText(slide.runs);
  if (!text.trim()) return [{ code: 'empty', message: 'Empty slide' }];
  if (lineCount > maxLines) w.push({ code: 'lines', message: `${lineCount} lines (max ${maxLines})` });
  const sp = americanSpellings(text);
  if (sp.length) w.push({ code: 'spelling', message: `US spelling: ${sp.join(', ')}` });
  if (slide.kind === 'scripture') {
    const nl = text.indexOf('\n');
    const body = nl >= 0 ? text.slice(nl + 1).trimStart() : '';
    const heading = nl >= 0 ? text.slice(0, nl) : text;
    if (!/\([^)]+\)\s*$/.test(heading)) w.push({ code: 'translation', message: 'No translation in the reference, e.g. (NLT)' });
    if (!body) w.push({ code: 'start', message: 'No verse text under the reference' });
    else if (!/^\d/.test(body)) w.push({ code: 'start', message: 'Body doesn’t start with a verse number' });
  } else {
    const first = /[\p{L}\p{N}]/u.exec(text.replace(/^[\s"'“‘.…]+/, ''));
    if (first && first[0] !== first[0].toUpperCase())
      w.push({ code: 'start', message: 'Doesn’t start with a capital letter' });
  }
  return w;
}
