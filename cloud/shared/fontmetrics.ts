import type { FontMetrics } from './types';

/** Reads unitsPerEm (head) and ascender/descender/lineGap (hhea) from a TrueType/OpenType file. */
export function readFontMetrics(buf: ArrayBuffer): FontMetrics {
  const v = new DataView(buf);
  const numTables = v.getUint16(4);
  const tables: Record<string, number> = {};
  for (let i = 0; i < numTables; i++) {
    const rec = 12 + i * 16;
    const tag = String.fromCharCode(v.getUint8(rec), v.getUint8(rec + 1), v.getUint8(rec + 2), v.getUint8(rec + 3));
    tables[tag] = v.getUint32(rec + 8);
  }
  if (tables.head === undefined || tables.hhea === undefined) throw new Error('font has no head/hhea table');
  return {
    unitsPerEm: v.getUint16(tables.head + 18),
    ascender: v.getInt16(tables.hhea + 4),
    descender: v.getInt16(tables.hhea + 6),
    lineGap: v.getInt16(tables.hhea + 8),
  };
}
