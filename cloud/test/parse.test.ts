import { describe, expect, it } from 'vitest';
import { detectKind, parseBlocks, parseQuote, parseReference, parseVerses, scriptureBody } from '../shared/parse';
import { JOHN, SOURCE } from './fixtures';

describe('parseReference', () => {
  it('reads book, chapter, verse and translation', () => {
    expect(parseReference('John 4:4-10 (NLT)')).toMatchObject({ book: 'John', chapter: 4, verse: 4, translation: 'NLT', heading: 'John 4:4-10 (NLT)' });
  });
  it('normalises square brackets and stray spaces', () => {
    expect(parseReference('  1  John 3 : 16 - 18  [ NIV ] ')?.heading).toBe('1 John 3:16-18 (NIV)');
    expect(parseReference('Song of Songs 2:4 (ESV)')?.book).toBe('Song of Songs');
  });
  it('rejects ordinary text', () => {
    expect(parseReference('FRESH OIL TRANSFORMS HOW I SEE MYSELF')).toBeNull();
    expect(parseReference('God is good: all the time')).toBeNull();
  });
});

describe('parseBlocks', () => {
  it('splits on blank lines and detects kinds', () => {
    const b = parseBlocks(SOURCE);
    expect(b.map((x) => x.kind)).toEqual(['scripture', 'point', 'scripture']);
    expect(b.map((x) => x.id)).toEqual(['b1', 'b2', 'b3']);
  });
  it('detects quotes', () => {
    expect(detectKind('"Faith is the first step." – MLK')).toBe('quote');
    expect(detectKind('“Grace”\nC.S. Lewis')).toBe('quote');
  });
  it('joins a following paragraph of continuing verses to the passage', () => {
    const b = parseBlocks('John 1:1-3 (NIV)\n1 In the beginning.\n\n2 He was with God. 3 Through him.');
    expect(b).toHaveLength(1);
    expect(parseVerses(scriptureBody(b[0].text), 1).map((v) => v.n)).toEqual([1, 2, 3]);
  });
});

describe('parseVerses', () => {
  it('splits sequential verse numbers only', () => {
    const v = parseVerses(scriptureBody(JOHN), 4);
    expect(v.map((x) => x.n)).toEqual([4, 5, 6, 7, 8, 9, 10]);
    expect(v[0].text).toBe('He had to go through Samaria on the way.');
  });
  it('keeps out-of-sequence numbers in the text', () => {
    const v = parseVerses('1 He chose 12 disciples. 2 They went.', 1);
    expect(v).toEqual([{ n: 1, text: 'He chose 12 disciples.' }, { n: 2, text: 'They went.' }]);
  });
});

describe('parseQuote', () => {
  it('author on its own line', () => {
    expect(parseQuote('"Be the church."\nJane Doe')).toEqual({ text: '"Be the church."', author: 'Jane Doe' });
  });
  it('author after a dash', () => {
    expect(parseQuote('“Be the church.” — Jane Doe')).toEqual({ text: '“Be the church.”', author: 'Jane Doe' });
  });
});
