import { describe, expect, it } from 'vitest';
import { countLines } from '../shared/layout';
import { markupToRuns, plainText, runsToMarkup } from '../shared/markup';
import { parseBlocks } from '../shared/parse';
import { scanQuotes } from '../shared/quotes';
import { buildSlides, fixOrphans, splitUnits } from '../shared/split';
import { americanSpellings, slideWarnings } from '../shared/warnings';
import { EZEKIEL, JOHN, POINT, SOURCE } from './fixtures';
import { ctxFor, fixedMeasure } from './helpers';

const ctx = ctxFor(fixedMeasure());
// Bodies with no-break spaces shown as plain spaces (where they go is checked separately).
const rawBody = (s: { runs: { t: string }[] }) => plainText(s.runs).split('\n').slice(1).join('\n');
const body = (s: { runs: { t: string }[] }) => rawBody(s).replace(/\u00a0/g, ' ');

describe('splitter (fixed-width measure)', () => {
  const slides = buildSlides(parseBlocks(SOURCE), ctx);
  const john = slides.filter((s) => s.id.startsWith('b1-'));

  it('puts the bold reference on every scripture slide', () => {
    for (const s of slides.filter((x) => x.kind === 'scripture')) {
      expect(s.runs[0].b).toBe(true);
      expect(s.runs[1].t.startsWith('\n')).toBe(true);
    }
    expect(john.every((s) => s.runs[0].t === 'John 4:4-10 (NLT)')).toBe(true);
  });

  it('keeps every body within 3 lines and starting with a verse number', () => {
    for (const s of slides.filter((x) => x.kind === 'scripture')) {
      expect(countLines([{ t: rawBody(s) }], ctx.small.width, ctx.small, ctx.measure)).toBeLessThanOrEqual(3);
      expect(body(s)).toMatch(/^\d+ /);
    }
  });

  it('never loses or reorders words', () => {
    const strip = (t: string) =>
      t.replace(/\u00a0/g, ' ').replace(/\d+ … /g, '').replace(/…/g, '').replace(/["“”]/g, '').replace(/\s+/g, ' ').trim();
    const joined = john.map((s) => body(s)).join(' ');
    expect(strip(joined)).toBe(strip(JOHN.split('\n')[1]));
  });

  it('keeps each verse number on the same line as its first word', () => {
    for (const s of john) {
      for (const m of rawBody(s).matchAll(/(?:^|[ \u00a0])(\d{1,3})([ \u00a0])(?!…)/g)) expect(m[2], `after verse ${m[1]}`).toBe('\u00a0');
    }
  });

  it('puts a no-break space between the last two words of every body', () => {
    for (const s of slides.filter((x) => x.style === 'small')) {
      const b = plainText(s.runs);
      expect(b.lastIndexOf('\u00a0')).toBeGreaterThan(b.lastIndexOf(' '));
    }
  });

  it('makes the short point big', () => {
    const p = slides.find((s) => s.kind === 'point')!;
    expect(p.style).toBe('big');
    expect(p.runs).toEqual([{ t: POINT, b: true }]);
  });

  it('splits a long verse mid-verse with ... and "<verse> ... "', () => {
    const long = { n: 35, text: Array(40).fill('word,').join(' ') + ' end' };
    const bodies = splitUnits([long], 3, ctx);
    expect(bodies.length).toBeGreaterThan(1);
    expect(bodies[0]).toMatch(/^35\u00a0/);
    expect(bodies[0].endsWith('…')).toBe(true);
    expect(bodies[0]).not.toMatch(/,…$/);
    expect(bodies[1]).toMatch(/^35 … /);
  });

  it('fills a one-line slide with the start of the next verse', () => {
    const v = [
      { n: 1, text: 'Short.' },
      { n: 2, text: Array(60).fill('long').join(' ') },
    ];
    const bodies = splitUnits(v, 3, ctx);
    expect(bodies[0]).toMatch(/^1\u00a0Short\. 2\u00a0long/);
    expect(bodies[0].endsWith('…')).toBe(true);
    expect(bodies[1]).toMatch(/^2 … long/);
  });

  it('prefers breaking after a comma or before "and"', () => {
    const words = Array(30).fill('alpha').join(' ') + ', ' + Array(40).fill('beta').join(' ');
    const bodies = splitUnits([{ n: 7, text: words }], 3, ctx);
    expect(bodies[0]).toMatch(/alpha,?\u00a0…$/);
    expect(bodies[1]).toMatch(/^7 … beta/);
  });

  it('closes open quotes at a split and reopens them on the next slide', () => {
    const text = '“' + Array(80).fill('word').join(' ') + '.”';
    const bodies = splitUnits([{ n: 3, text }], 3, ctx);
    expect(bodies[0].endsWith('…”')).toBe(true);
    expect(bodies[1]).toMatch(/^3 … “word/);
    expect(bodies[bodies.length - 1].endsWith('.”')).toBe(true);
  });

  it('splits quotes and keeps the author bold on each slide', () => {
    const q = '"' + Array(70).fill('grace').join(' ') + '."\nJane Doe';
    const s = buildSlides(parseBlocks(q), ctx);
    expect(s.length).toBeGreaterThan(1);
    for (const x of s) expect(x.runs[x.runs.length - 1]).toEqual({ t: '\nJane Doe', b: true });
    expect(plainText(s[0].runs)).toMatch(/…"\n/);
  });
});

describe('quotes', () => {
  it('ignores apostrophes', () => {
    expect(scanQuotes("Jacob's well")).toEqual([]);
    expect(scanQuotes('Jacob’s well')).toEqual([]);
  });
  it('tracks nested quotes', () => {
    expect(scanQuotes(`"This is what he says, 'come`)).toEqual(['"', "'"]);
    expect(scanQuotes(`people!' 36 Then`, ['"', "'"])).toEqual(['"']);
  });
});

describe('markup', () => {
  it('round-trips runs', () => {
    const runs = [{ t: 'Ezekiel 36:33-36 (NLT)', b: true }, { t: '\n35 … text' }];
    expect(runsToMarkup(runs)).toBe('**Ezekiel 36:33-36 (NLT)**\n35 … text');
    expect(markupToRuns(runsToMarkup(runs))).toEqual(runs);
  });
  it('fixOrphans moves the NBSP to the new last two words', () => {
    const s = fixOrphans({ id: 'x', kind: 'scripture', style: 'small', runs: [{ t: 'H', b: true }, { t: '\n1 a\u00a0b c d' }] });
    expect(plainText(s.runs)).toBe('H\n1\u00a0A b c\u00a0d');
  });
});

describe('warnings', () => {
  it('finds American spellings', () => {
    expect(americanSpellings('We honor the Savior, realize his favor and are centered.')).toEqual([
      'honor → honour', 'Savior → Saviour', 'favor → favour', 'centered → centred', 'realize → realise',
    ]);
    expect(americanSpellings('honour the prize and size')).toEqual([]);
  });
  it('flags lines, verse start and capitals', () => {
    const w = slideWarnings({ id: 'a', kind: 'scripture', style: 'small', runs: [{ t: 'John 1:1 (NIV)', b: true }, { t: '\nin the beginning' }] }, 5, 4);
    expect(w.map((x) => x.code)).toEqual(['lines', 'start']);
    expect(slideWarnings({ id: 'b', kind: 'point', style: 'big', runs: [{ t: 'grace', b: true }] }, 1, 1)[0].code).toBe('start');
  });
});

it('Ezekiel fixture splits into numbered slides', () => {
  const s = buildSlides(parseBlocks(EZEKIEL), ctx);
  expect(s.length).toBeGreaterThanOrEqual(4);
  expect(body(s[0])).toMatch(/^33 "/);
});

describe('layoutText (FORMAT.md "Text layout")', () => {
  it('uses 5 pt padding, pitch (A+D+G)*lineHeight, baseline top+i*P+A and block height with +5', async () => {
    const { layoutText, wrapWidth } = await import('../shared/layout');
    const { THEMES } = await import('../shared/themes');
    const st = THEMES.central.styles.small; // bottom-aligned, lineHeight 0.9, size 54
    const metrics = { unitsPerEm: 2048, ascender: 1606, descender: -442, lineGap: 307 };
    const k = 54 / 2048;
    const [A, D, G] = [1606 * k, 442 * k, 307 * k];
    const P = (A + D + G) * 0.9;
    const L = layoutText([{ t: 'Heading', b: true }, { t: '\nbody' }], st, fixedMeasure(), metrics);
    const H = P + A + D + G + 5;
    const top = st.rect[1] + st.rect[3] - H;
    expect(L.lines.map((l) => l.x)).toEqual([st.rect[0] + 5, st.rect[0] + 5]);
    expect(L.lines[0].baseline).toBeCloseTo(top + A, 6);
    expect(L.lines[1].baseline).toBeCloseTo(top + P + A, 6);
    expect(wrapWidth(1692.806)).toBeCloseTo(1682.806, 6);
  });
});
