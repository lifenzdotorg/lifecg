import { describe, expect, it } from 'vitest';
import { colourName, type DocParagraph, highlightSummary, paragraphsToSource } from '../shared/docimport';

const P = (text: string, highlight: string | null, extra: Partial<DocParagraph> = {}): DocParagraph => ({ text, highlight, bold: false, gapBefore: false, ...extra });

describe('document import', () => {
  const doc = [
    P('Intro prose.', null),
    P('Psalm 119:103 (NIV)', 'yellow'),
    P('103 How sweet are your words to my taste,', 'yellow'),
    P('   sweeter than honey to my mouth!', 'yellow'),
    P('More prose.', null),
    P('The Problem: Proximity', 'green'),
    P('Consider the invitation', 'green'),
    P('Think about the proximity problem - What voices and environments am I', 'green'),
    P('allowing to shape me?', 'green', { wrapped: true }),
    P('Example: a story.', 'cyan'),
    P('1. Practice the solution - What would it look like? Not highlighted', 'green', { highlightedText: 'Practice the solution - What would it look like?' }),
  ];
  it('keeps a scripture together and points apart', () => {
    expect(paragraphsToSource(doc, ['yellow', 'green']).split('\n\n')).toEqual([
      'Psalm 119:103 (NIV)\n103 How sweet are your words to my taste,\nsweeter than honey to my mouth!',
      'The Problem: Proximity',
      'Consider the invitation',
      'Think about the proximity problem - What voices and environments am I allowing to shape me?',
      'Practice the solution - What would it look like?',
    ]);
  });
  it('summarises the highlight colours', () => {
    expect(highlightSummary(doc).map((h) => [h.colour, h.count])).toEqual([
      ['green', 5],
      ['yellow', 3],
      ['cyan', 1],
    ]);
  });
  it('names fill colours and ignores white, black and greys', () => {
    expect(colourName(255, 255, 0)).toBe('yellow');
    expect(colourName(0, 255, 0)).toBe('green');
    expect(colourName(0, 255, 255)).toBe('cyan');
    expect(colourName(255, 255, 255)).toBeNull();
    expect(colourName(0, 0, 0)).toBeNull();
    expect(colourName(200, 200, 200)).toBeNull();
  });
});
