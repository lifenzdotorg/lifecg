// Client-side PDF for a push: title page, then each slide's rendered lower third with its plain text.
import { PDFDocument, rgb, StandardFonts, type PDFFont } from 'pdf-lib';
import { plainText } from '../../shared/markup';
import { previewCrop } from '../../shared/themes';
import { formatServiceDate } from '../../shared/time';
import type { Slide, Theme } from '../../shared/types';
import type { Fonts } from './fonts';
import { loadThemeImages, renderSlide } from './render';

export interface PdfInfo {
  title: string;
  speaker: string;
  serviceLabel: string;
  startsAt: string;
  version: number;
  pushedBy: string;
}

const A4: [number, number] = [595.28, 841.89];
const M = 42;

/** Helvetica (WinAnsi) can't draw every character; strip accents and replace the rest. */
function sanitizer(font: PDFFont) {
  const ok = new Set(font.getCharacterSet());
  return (s: string) =>
    [...s.replace(/\u00a0/g, ' ')]
      .map((ch) => {
        if (ok.has(ch.codePointAt(0)!) || ch === '\n') return ch;
        const base = ch.normalize('NFD').replace(/\p{M}/gu, '');
        return [...base].every((c) => ok.has(c.codePointAt(0)!)) ? base : '?';
      })
      .join('');
}

function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const out: string[] = [];
  for (const para of text.split('\n')) {
    let line = '';
    for (const word of para.split(' ')) {
      const cand = line ? `${line} ${word}` : word;
      if (line && font.widthOfTextAtSize(cand, size) > width) {
        out.push(line);
        line = word;
      } else line = cand;
    }
    out.push(line);
  }
  return out;
}

async function canvasJpeg(canvas: HTMLCanvasElement): Promise<Uint8Array> {
  const blob = await new Promise<Blob>((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error('toBlob failed'))), 'image/jpeg', 0.88));
  return new Uint8Array(await blob.arrayBuffer());
}

export async function buildNotesPdf(info: PdfInfo, slides: Slide[], theme: Theme, fonts: Fonts): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.setTitle(`Speaker notes: ${info.title}`);
  doc.setCreator('LifeCG notes portal');
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const clean = sanitizer(reg);
  const grey = rgb(0.42, 0.42, 0.45);
  const ink = rgb(0.11, 0.11, 0.12);

  // Title page
  let page = doc.addPage(A4);
  let y = A4[1] - 140;
  page.drawText('SPEAKER NOTES', { x: M, y, size: 11, font: bold, color: grey });
  y -= 40;
  for (const line of wrap(clean(info.title || 'Untitled'), bold, 30, A4[0] - 2 * M)) {
    page.drawText(line, { x: M, y, size: 30, font: bold, color: ink });
    y -= 36;
  }
  y -= 10;
  const rows: [string, string][] = [
    ['Speaker', info.speaker],
    ['Service', info.serviceLabel],
    ['When', formatServiceDate(info.startsAt)],
    ['Version', info.version > 1 ? `${info.version} (updated)` : String(info.version)],
    ['Theme', theme.name],
    ['Slides', String(slides.length)],
    ['Pushed by', info.pushedBy],
    ['Created', new Date().toLocaleString('en-NZ', { timeZone: 'Pacific/Auckland' })],
  ];
  for (const [k, v] of rows) {
    page.drawText(k, { x: M, y, size: 12, font: reg, color: grey });
    page.drawText(clean(v || '-'), { x: M + 90, y, size: 12, font: reg, color: ink });
    y -= 20;
  }

  // Slides, several per page
  const crop = previewCrop(theme);
  const imgs = await loadThemeImages(theme);
  const canvas = document.createElement('canvas');
  const imgW = A4[0] - 2 * M;
  const imgH = (imgW * crop.h) / theme.canvas[0];
  page = doc.addPage(A4);
  y = A4[1] - M;
  for (let i = 0; i < slides.length; i++) {
    const s = slides[i];
    const lines = wrap(clean(plainText(s.runs)), reg, 9.5, imgW);
    const need = 14 + imgH + 8 + lines.length * 12.5 + 18;
    if (y - need < M) {
      page = doc.addPage(A4);
      y = A4[1] - M;
    }
    page.drawText(`${i + 1}  ·  ${s.kind}${s.style === 'big' ? ' (big)' : ''}`, { x: M, y: y - 9, size: 8.5, font: bold, color: grey });
    y -= 14;
    renderSlide(canvas, theme, s, fonts, imgs, { scale: 0.75, crop });
    const jpg = await doc.embedJpg(await canvasJpeg(canvas));
    page.drawImage(jpg, { x: M, y: y - imgH, width: imgW, height: imgH });
    y -= imgH + 8;
    // the plain text, with the bold runs bold
    const boldLines = new Set<number>();
    if (s.runs[0]?.b) boldLines.add(0); // heading / point
    for (const [j, line] of lines.entries()) {
      const f = boldLines.has(j) || s.kind === 'point' ? bold : reg;
      page.drawText(line, { x: M, y: y - 9.5, size: 9.5, font: f, color: ink });
      y -= 12.5;
    }
    y -= 18;
  }
  const n = doc.getPageCount();
  doc.getPages().forEach((p, i) => {
    if (i === 0) return;
    p.drawText(clean(`${info.title}  ·  ${info.serviceLabel} ${formatServiceDate(info.startsAt)}  ·  v${info.version}  ·  ${i + 1}/${n}`), {
      x: M,
      y: 20,
      size: 8,
      font: reg,
      color: grey,
    });
  });
  return doc.save();
}
