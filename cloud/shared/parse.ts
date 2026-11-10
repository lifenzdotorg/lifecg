// Pasted notes -> blocks (FORMAT.md "Scripture input", PLAN.md "Content model").
import type { Block, SlideKind } from './types';

export interface Reference {
  book: string;
  chapter: number;
  verse: number | null; // first verse
  translation: string | null;
  /** normalised heading, e.g. `John 4:4-10 (NLT)` */
  heading: string;
}

const BOOK = String.raw`(?:[1-3]\s*)?\p{Lu}[\p{L}.']*(?:\s+(?:of\s+)?\p{Lu}[\p{L}.']*){0,3}`;

/** Translation names PAs write out in full (or copy from Bible Gateway) -> the abbreviation on the slide. */
const TRANSLATION_NAMES: Record<string, string> = {
  'new living translation': 'NLT', 'new international version': 'NIV', 'english standard version': 'ESV',
  'new king james version': 'NKJV', 'king james version': 'KJV', 'new american standard bible': 'NASB',
  'the message': 'MSG', message: 'MSG', 'amplified bible': 'AMP', 'amplified bible, classic edition': 'AMPC',
  'christian standard bible': 'CSB', 'new revised standard version': 'NRSV', 'the passion translation': 'TPT',
  'new century version': 'NCV', 'good news translation': 'GNT', 'contemporary english version': 'CEV',
  'new english translation': 'NET', 'berean standard bible': 'BSB', "new international reader's version": 'NIRV',
};
const TRANSLATION_ABBR = 'NLT|NIV|ESV|NKJV|KJV|NASB|NASB1995|MSG|AMP|AMPC|CSB|HCSB|NRSV|NRSVUE|TPT|NCV|GNT|CEV|NET|BSB|NIRV|NIrV|RSV|LSB|WEB';
const BARE_TRANSLATION = String.raw`${TRANSLATION_ABBR}|${Object.keys(TRANSLATION_NAMES).map((n) => n.replace(/ /g, String.raw`\s+`)).join('|')}`;

// `John 4:4-10 (NLT)`, `1 John 3:16 [NIV]`, `Psalm 1 NIV`, `John 17:16-18 New Living Translation`, `Psalm 23`
const REF_RE = new RegExp(
  String.raw`^\s*(${BOOK})\s+(\d{1,3})(?:\s*:\s*(\d{1,3})([\d\s:,;\-–—]*?))?\s*(?:[(\[]\s*([\p{L}\d][\p{L}\d ,'\-]*?)\s*[)\]]|(${BARE_TRANSLATION}))?\s*$`,
  'iu',
);

export function normaliseTranslation(t: string): string {
  const k = t.replace(/\s+/g, ' ').trim();
  return TRANSLATION_NAMES[k.toLowerCase()] ?? (new RegExp(`^(${TRANSLATION_ABBR})$`, 'i').test(k) ? k.toUpperCase().replace('NIRV', 'NIrV') : k);
}

/** Recognises a scripture heading line such as `John 4:4-10 (NLT)`, `1 John 3:16 [NIV]` or `Psalm 1 NIV`. */
export function parseReference(line: string): Reference | null {
  const m = REF_RE.exec(line);
  if (!m) return null;
  // The book must start with a capital (the regex is case-insensitive only for the translation).
  if (!/^(?:[1-3]\s*)?\p{Lu}/u.test(m[1])) return null;
  const book = m[1].replace(/\s+/g, ' ').replace(/^([1-3])\s*/, '$1 ').trim();
  const chapter = Number(m[2]);
  const verse = m[3] ? Number(m[3]) : null;
  const rest = (m[4] ?? '').replace(/\s+/g, '').replace(/,(?=\S)/g, ', ');
  const raw = m[5] ?? m[6];
  const translation = raw ? normaliseTranslation(raw) : null;
  const heading = `${book} ${chapter}${verse !== null ? `:${verse}${rest}` : ''}${translation ? ` (${translation})` : ''}`;
  return { book, chapter, verse, translation, heading };
}

const QUOTE_START = /^\s*["“‘'«]/;

export function detectKind(text: string): SlideKind {
  const [first, ...rest] = text.split('\n');
  const ref = parseReference(first);
  // "Psalm 23" on its own could be a point; it's scripture when it has a verse, a translation or verse text.
  if (ref && (ref.verse !== null || ref.translation || /^\s*\d/.test(rest.join(' ')))) return 'scripture';
  if (QUOTE_START.test(text)) return 'quote';
  return 'point';
}

/** Splits pasted notes into blocks on blank lines. A paragraph of numbered verses that follows a
 *  scripture block (no heading of its own) is joined to that passage. */
export function parseBlocks(source: string): Block[] {
  const paras = source
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t]+$/gm, '')
    .split(/\n\s*\n/)
    .map((p) => p.replace(/^\n+|\n+$/g, ''))
    .filter((p) => p.trim() !== '');
  const blocks: Block[] = [];
  for (const p of paras) {
    const kind = detectKind(p);
    const prev = blocks[blocks.length - 1];
    if (kind !== 'scripture' && prev?.kind === 'scripture' && /^\s*\d{1,3}\s*\S/.test(p)) {
      // A heading on its own paragraph, with the verses in the next one (common when copying from a PDF).
      if (!scriptureBody(prev.text)) {
        prev.text += '\n' + p;
        continue;
      }
      const verses = parseVerses(scriptureBody(prev.text), parseReference(prev.text.split('\n')[0])?.verse ?? null);
      const last = verses[verses.length - 1]?.n;
      const firstNum = Number(/^\s*(\d{1,3})/.exec(p)![1]);
      // later verses of the same passage (a PA may skip some verses)
      if (last !== null && last !== undefined && firstNum > last && firstNum <= last + 20) {
        prev.text += '\n' + p;
        continue;
      }
    }
    blocks.push({ id: `b${blocks.length + 1}`, kind, text: p });
  }
  return blocks;
}

export function scriptureBody(text: string): string {
  return text.split('\n').slice(1).join(' ').replace(/\s+/g, ' ').trim();
}

export interface Verse {
  n: number | null;
  text: string;
}

/** Splits a passage body into verses on verse numbers that run in sequence (`4 He had… 5 Eventually…`).
 *  Numbers out of sequence (e.g. "12 disciples") stay in the text. */
export function parseVerses(body: string, firstVerse: number | null): Verse[] {
  const text = body.replace(/\s+/g, ' ').trim();
  // A verse number may follow a space or sentence punctuation (`away.5 Therefore`) and may be glued to its
  // first word (`1Blessed`, `2but` from a PDF's superscripts); it only counts when it's the next in sequence.
  const re = /(^|\s|(?<=[.,;!?”’"—)]))(\d{1,3})(?=\s|[\p{L}"“‘'])/gu;
  const marks: { at: number; numEnd: number; n: number }[] = [];
  let expect: number | null = null;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    const n = Number(m[2]);
    const at = m.index + m[1].length;
    // Skipped verses (1-2, then 4) count only after the end of a sentence or when glued to the word,
    // so a number in the text ("the 12 disciples") isn't taken for a verse.
    const before = text.slice(0, at).trimEnd().slice(-1);
    const glued = /\p{L}/u.test(text[at + m[2].length] ?? '');
    const jump = expect !== null && n > expect && n <= expect + 10 && (/[.!?;”’"—)]/.test(before) || glued);
    const ok = marks.length === 0 ? at === 0 && (firstVerse === null || n === firstVerse || n > 0) : n === expect || jump;
    if (ok) {
      marks.push({ at, numEnd: at + m[2].length, n });
      expect = n + 1;
    }
  }
  if (marks.length === 0) return text ? [{ n: null, text }] : [];
  const verses: Verse[] = [];
  if (marks[0].at > 0) verses.push({ n: null, text: text.slice(0, marks[0].at).trim() });
  marks.forEach((mk, i) => {
    const end = i + 1 < marks.length ? marks[i + 1].at : text.length;
    verses.push({ n: mk.n, text: text.slice(mk.numEnd, end).trim() });
  });
  return verses;
}

export interface ParsedQuote {
  text: string;
  author: string | null;
}

/** Quote block: the quotation, then the author on the last line or after a dash (`"…" - C.S. Lewis`). */
export function parseQuote(block: string): ParsedQuote {
  const lines = block.split('\n').map((l) => l.trim()).filter(Boolean);
  let author: string | null = null;
  if (lines.length > 1 && !/["”’']\s*$/.test(lines[lines.length - 1])) {
    author = lines.pop()!.replace(/^[-–—~]\s*/, '');
  } else {
    const last = lines[lines.length - 1];
    const m = /^(.*["”’'])\s*[-–—~]\s*([^"”’]+)$/.exec(last);
    if (m) {
      lines[lines.length - 1] = m[1];
      author = m[2].trim();
    }
  }
  return { text: lines.join(' ').replace(/\s+/g, ' '), author };
}
