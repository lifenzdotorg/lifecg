// Uses the real Neuzeit fonts from cloud/.fonts (never committed); skipped when they are absent.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { readFontMetrics } from '../shared/fontmetrics';
import { wrapRuns, wrapWidth } from '../shared/layout';
import { plainText } from '../shared/markup';
import { parseBlocks } from '../shared/parse';
import { buildSlides } from '../shared/split';
import { THEMES } from '../shared/themes';
import { SOURCE } from './fixtures';
import { ctxFor } from './helpers';
import { FONT_FILES, fontsPresent, realMeasure } from './realfont';

describe.skipIf(!fontsPresent)('real Neuzeit metrics', () => {
  const measure = realMeasure()!;
  const ctx = ctxFor(measure);
  const slides = buildSlides(parseBlocks(SOURCE), ctx);

  it('splits John 4:4-10 like LIFE’s Central deck: [4-5] [6] [7] [8] [9] [10]', () => {
    const verses = slides
      .filter((s) => s.id.startsWith('b1-'))
      .map((s) => [...plainText(s.runs).split('\n')[1].matchAll(/(?:^|\s)(\d+)(?=[\s\u00a0])/g)].map((m) => Number(m[1])));
    expect(verses).toEqual([[4, 5], [6], [7], [8], [9], [10]]);
  });

  it('wraps lines exactly where ProPresenter did (Central deck, 18 Oct 2026)', () => {
    const st = THEMES.central.styles.small;
    const lines = (t: string) => wrapRuns([{ t }], wrapWidth(st.rect[2]), st, measure).map((l) => l.segs.map((s) => s.t).join(''));
    expect(lines('4 He had to go through Samaria on the way. 5 Eventually he came to the Samaritan village of Sychar, near the field that Jacob gave to his son Joseph.')).toEqual([
      '4 He had to go through Samaria on the way. 5 Eventually he came',
      'to the Samaritan village of Sychar, near the field that Jacob gave to',
      'his son Joseph.',
    ]);
    expect(lines('9 The woman was surprised, for Jews refuse to have anything to do with Samaritans. She said to Jesus, “You are a Jew, and I am a Samaritan woman. Why are you asking me for a drink?”')).toEqual([
      '9 The woman was surprised, for Jews refuse to have anything to do',
      'with Samaritans. She said to Jesus, “You are a Jew, and I am a',
      'Samaritan woman. Why are you asking me for a drink?”',
    ]);
  });

  it('the point is one line at the big size', () => {
    expect(slides.find((s) => s.kind === 'point')!.style).toBe('big');
  });

  it('every scripture slide is at most 4 lines in both themes', () => {
    for (const theme of Object.values(THEMES)) {
      const st = theme.styles.small;
      for (const s of slides.filter((x) => x.kind === 'scripture')) expect(wrapRuns(s.runs, wrapWidth(st.rect[2]), st, measure).length).toBeLessThanOrEqual(4);
    }
  });

  it('reads hhea metrics', () => {
    const b = readFileSync(FONT_FILES['NeuzeitGro-Reg']);
    expect(readFontMetrics(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength))).toEqual({ unitsPerEm: 2048, ascender: 1606, descender: -442, lineGap: 307 });
  });
});
