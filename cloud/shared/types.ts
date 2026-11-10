// Shared types: the contract in docs/notes-platform/FORMAT.md.

export interface Run {
  t: string;
  b?: boolean;
}

export type SlideKind = 'scripture' | 'point' | 'quote';
export type StyleName = 'small' | 'big';

export interface Slide {
  id: string;
  kind: SlideKind;
  style: StyleName;
  runs: Run[];
}

export type Rect = [number, number, number, number];

export interface ThemeLayer {
  type: 'image' | 'rect';
  src?: string;
  rect: Rect;
  color?: string;
  opacity?: number;
}

export interface ThemeStyle {
  rect: Rect;
  regularFont: string;
  boldFont: string;
  size: number;
  tracking: number;
  lineHeight: number;
  align: 'left' | 'center' | 'right';
  valign: 'top' | 'middle' | 'bottom';
  maxLines: number;
}

export interface Theme {
  id: string;
  name: string;
  source?: string;
  canvas: [number, number];
  layers: ThemeLayer[];
  text: {
    color: string;
    strokePercent: number;
    strokeColor: string;
    shadow: { angle: number; offset: number; blur: number; color: string };
  };
  styles: Record<StyleName, ThemeStyle>;
}

/** A pasted block of source text, before splitting. */
export interface Block {
  id: string;
  kind: SlideKind;
  text: string;
}

/** Raw advance width of `text` in `font` (PostScript name) at `size` px, kerning on, no tracking. */
export type Measure = (text: string, font: string, size: number) => number;

/** Vertical font metrics in font units (hhea). */
export interface FontMetrics {
  unitsPerEm: number;
  ascender: number;
  descender: number; // negative
  lineGap: number;
}
