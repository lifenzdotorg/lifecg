import { wrapWidth } from '../shared/layout';
import type { SplitContext } from '../shared/split';
import { splitStyle } from '../shared/themes';
import type { Measure } from '../shared/types';

export function ctxFor(measure: Measure): SplitContext {
  const s = splitStyle('small');
  const b = splitStyle('big');
  return { measure, small: { ...s, width: wrapWidth(s.rect[2]) }, big: { ...b, width: wrapWidth(b.rect[2]) } };
}

/** Fixed-advance measure: every character is `em` x size wide (no kerning). */
export const fixedMeasure = (em = 0.45): Measure => (text, _font, size) => [...text].length * em * size;
