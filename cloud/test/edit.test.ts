import { expect, it } from 'vitest';
import { mergeSlides, splitSlideAt } from '../shared/edit';
import { fixOrphans } from '../shared/split';
import { plainText, runsToMarkup } from '../shared/markup';
import type { Slide } from '../shared/types';

const sc: Slide = { id: 'b1-1', kind: 'scripture', style: 'small', runs: [{ t: 'John 4:4-10 (NLT)', b: true }, { t: '\n9 The woman was surprised, for Jews refuse to\u00a0know.' }] };

it('splits scripture mid-verse with ... and keeps the heading', () => {
  const m = runsToMarkup(sc.runs);
  const [a, b] = splitSlideAt(sc, m, m.indexOf(' for Jews'), 'b1-9');
  expect(plainText(a.runs)).toBe('John 4:4-10 (NLT)\n9\u00a0The woman was\u00a0surprised,\u00a0…');
  expect(plainText(b.runs)).toBe('John 4:4-10 (NLT)\n9\u00a0… For Jews refuse to\u00a0know.');
  expect(b.id).toBe('b1-9');
  expect(b.runs[0]).toEqual({ t: 'John 4:4-10 (NLT)', b: true });
});

it('splits at a verse boundary without dots, and merging undoes a mid-verse split', () => {
  const s: Slide = { ...sc, runs: [{ t: 'John 4:4-10 (NLT)', b: true }, { t: '\n4 One. 5 Two\u00a0words.' }] };
  const m = runsToMarkup(s.runs);
  const [a, b] = splitSlideAt(s, m, m.indexOf('5 Two'), 'x');
  expect(plainText(a.runs)).toBe('John 4:4-10 (NLT)\n4\u00a0One.');
  expect(plainText(b.runs)).toBe('John 4:4-10 (NLT)\n5\u00a0Two\u00a0words.');
  const m2 = runsToMarkup(sc.runs);
  const [c, d] = splitSlideAt(sc, m2, m2.indexOf(' to\u00a0know'), 'y');
  expect(plainText(d.runs)).toMatch(/\n9\u00a0… To/);
  expect(plainText(mergeSlides(c, d).runs)).toBe(plainText(fixOrphans(sc).runs));
});

it('splits inside bold without breaking the markup', () => {
  const p: Slide = { id: 'p', kind: 'point', style: 'small', runs: [{ t: 'ONE TWO THREE FOUR', b: true }] };
  const [a, b] = splitSlideAt(p, '**ONE TWO THREE FOUR**', 9, 'q');
  expect(a.runs).toEqual([{ t: 'ONE\u00a0TWO', b: true }]);
  expect(b.runs).toEqual([{ t: 'THREE\u00a0FOUR', b: true }]);
});

it('keeps the punctuation, with a space before the …', () => {
  const s: Slide = { ...sc, runs: [{ t: 'John 4:4-10 (NLT)', b: true }, { t: '\n9 One sentence. Another one here.' }] };
  const m = runsToMarkup(s.runs);
  const [a, b] = splitSlideAt(s, m, m.indexOf(' Another'), 'z');
  expect(plainText(a.runs)).toBe('John 4:4-10 (NLT)\n9\u00a0One\u00a0sentence.\u00a0…');
  expect(plainText(b.runs)).toBe('John 4:4-10 (NLT)\n9\u00a0… Another one\u00a0here.');
});
