import { describe, expect, it } from 'vitest';
import { plainText } from '../shared/markup';
import { parseBlocks, parseReference, parseVerses, scriptureBody } from '../shared/parse';
import { buildSlides } from '../shared/split';
import { ctxFor, fixedMeasure } from './helpers';

// As pasted in the portal on 10 Nov 2026 (Psalm 1, 8 Nov PM service): no brackets, no verse in the
// heading, poetry line breaks and "away.5" with no space.
const PASTED = `Psalm 1 NIV
1 Blessed is the one
who does not walk in step with the wicked
or stand in the way that sinners take
or sit in the company of mockers,
2 but whose delight is in the law of the Lord,
and who meditates on his law day and night.
3 That person is like a tree planted by streams of water,
which yields its fruit in season
and whose leaf does not wither—
whatever they do prospers.
4 Not so the wicked!
They are like chaff
that the wind blows away.5 Therefore the wicked will not stand in the judgment,
nor sinners in the assembly of the righteous.
6 For the Lord watches over the way of the righteous,
but the way of the wicked leads to destruction.`;

// The same passage as text copied out of the PDF (superscript verse numbers lose their space).
const FROM_PDF = `Psalm 1 NIV

1Blessed is the one
 who does not walk in step with the wicked
or stand in the way that sinners take
 or sit in the company of mockers,
2but whose delight is in the law of the Lord,
 and who meditates on his law day and night.

4Not so the wicked!
 They are like chaff
 that the wind blows away.`;

describe('scripture headings', () => {
  it.each([
    ['Psalm 1 NIV', 'Psalm 1 (NIV)'],
    ['John 17:16-18 New Living Translation', 'John 17:16-18 (NLT)'],
    ['Romans 12:2  (NIV)', 'Romans 12:2 (NIV)'],
    ['Psalm 119:103 (NIV)', 'Psalm 119:103 (NIV)'],
    ['Matthew 7:13-14 (NIV)', 'Matthew 7:13-14 (NIV)'],
    ['1 John 3:16 [esv]', '1 John 3:16 (ESV)'],
    ['John 4:4-10 (NLT)', 'John 4:4-10 (NLT)'],
  ])('%s -> %s', (line, heading) => {
    expect(parseReference(line)?.heading).toBe(heading);
  });
  it('does not take a sentence for a heading', () => {
    for (const l of ['Psalm 1 starts with an invitation to be planted.', 'The Problem: Proximity', 'Chapter 3 begins here']) expect(parseReference(l)).toBeNull();
  });
});

describe('Psalm 1 as pasted', () => {
  const ctx = ctxFor(fixedMeasure());
  it('is one scripture block, all six verses', () => {
    const blocks = parseBlocks(PASTED);
    expect(blocks.map((b) => b.kind)).toEqual(['scripture']);
    expect(parseVerses(scriptureBody(blocks[0].text), null).map((v) => v.n)).toEqual([1, 2, 3, 4, 5, 6]);
  });
  it('reflows over several slides, each with the bold heading and at most 3 lines', () => {
    const slides = buildSlides(parseBlocks(PASTED), ctx);
    expect(slides.length).toBeGreaterThan(2);
    for (const s of slides) {
      expect(s.kind).toBe('scripture');
      expect(s.runs[0]).toEqual({ t: 'Psalm 1 (NIV)', b: true });
      expect(s.runs.slice(1).some((r) => r.b)).toBe(false);
    }
    const all = slides.map((s) => plainText(s.runs).split('\n').slice(1).join(' ')).join(' ');
    expect(all).toMatch(/away\. 5 Therefore/);
  });
  it('reads verse numbers glued to the text and a heading on its own paragraph', () => {
    const blocks = parseBlocks(FROM_PDF);
    expect(blocks.map((b) => b.kind)).toEqual(['scripture']);
    expect(parseVerses(scriptureBody(blocks[0].text), null).map((v) => [v.n, v.text.slice(0, 7)])).toEqual([
      [1, 'Blessed'],
      [2, 'but who'],
      [4, 'Not so '],
    ]);
  });
  it('keeps numbers in the text that are not verse numbers', () => {
    expect(parseVerses('1 Jesus called the 12 disciples. 2 Then he sent them out.', null).map((v) => v.n)).toEqual([1, 2]);
  });
});

import { capitaliseStart } from '../shared/split';
describe('every slide starts with a capital', () => {
  const sc = (body: string) => ({ id: 'x', kind: 'scripture' as const, style: 'small' as const, runs: [{ t: 'Psalm 1 (NIV)', b: true }, { t: '\n' + body }] });
  it.each([
    ['2 but whose delight is in the law', '2 But whose delight is in the law'],
    ['35 … this former wasteland', '35 … This former wasteland'],
    ['9 “for Jews refuse', '9 “For Jews refuse'],
    ['2 but whose', '2 But whose'],
    ['3 That person', '3 That person'],
  ])('%s', (body, want) => {
    expect(plainText(capitaliseStart(sc(body)).runs)).toBe('Psalm 1 (NIV)\n' + want);
  });
  it('capitalises points and quotes too, and leaves the heading alone', () => {
    expect(capitaliseStart({ id: 'p', kind: 'point', style: 'big', runs: [{ t: 'when I’m rooted in God', b: true }] }).runs[0].t).toBe('When I’m rooted in God');
    expect(capitaliseStart({ id: 'q', kind: 'quote', style: 'small', runs: [{ t: '… and so we go' }] }).runs[0].t).toBe('… And so we go');
  });
  it('applies when Psalm 1 is split', () => {
    const slides = buildSlides(parseBlocks(PASTED), ctxFor(fixedMeasure()));
    for (const s of slides) expect(plainText(s.runs).split('\n')[1]).toMatch(/^\d+[  ](?:… )?[“"]?\p{Lu}/u);
  });
});
