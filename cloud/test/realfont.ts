// Measure function backed by the real Neuzeit TTFs (cloud/.fonts), via opentype.js. Null when fonts are absent.
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import opentype from 'opentype.js';
import type { Measure } from '../shared/types';

const dir = fileURLToPath(new URL('../.fonts/', import.meta.url));
export const FONT_FILES = { 'NeuzeitGro-Reg': dir + 'NeuzeitGro-Reg.ttf', 'NeuzeitGro-Bol': dir + 'NeuzeitGro-Bol.ttf' };
export const fontsPresent = Object.values(FONT_FILES).every((f) => existsSync(f));

export function realMeasure(): Measure | null {
  if (!fontsPresent) return null;
  const fonts: Record<string, opentype.Font> = {};
  for (const [name, file] of Object.entries(FONT_FILES)) {
    const b = readFileSync(file);
    fonts[name] = opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
  }
  return (text, font, size) => fonts[font].getAdvanceWidth(text, size, { kerning: true });
}
