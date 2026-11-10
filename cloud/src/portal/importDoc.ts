// Reads a PA's PDF or Word document in the browser (nothing is uploaded to read it).
import { unzipSync } from 'fflate';
import { type DocParagraph, docxParagraphs, type PdfJs, pdfParagraphs } from '../../shared/docimport';

// pdf.js is large, so it's only fetched when someone imports a PDF (copied to /vendor by the build).
const PDFJS_URL = '/vendor/pdf.min.mjs';
const PDFJS_WORKER_URL = '/vendor/pdf.worker.min.mjs';
let pdfjsPromise: Promise<PdfJs> | null = null;
function loadPdfJs(): Promise<PdfJs> {
  pdfjsPromise ??= (import(/* @vite-ignore */ PDFJS_URL) as Promise<PdfJs & { GlobalWorkerOptions: { workerSrc: string } }>).then((m) => {
    m.GlobalWorkerOptions.workerSrc = PDFJS_WORKER_URL;
    return m;
  });
  return pdfjsPromise;
}

export type DocKind = 'pdf' | 'docx' | 'doc' | 'text';

export function docKind(file: File, bytes: Uint8Array): DocKind | null {
  if (new TextDecoder().decode(bytes.subarray(0, 5)) === '%PDF-') return 'pdf';
  if (bytes[0] === 0x50 && bytes[1] === 0x4b) return 'docx';
  if (bytes[0] === 0xd0 && bytes[1] === 0xcf && bytes[2] === 0x11 && bytes[3] === 0xe0) return 'doc';
  if (/\.(txt|md|rtf)$/i.test(file.name) || file.type.startsWith('text/')) return 'text';
  return null;
}

export async function readDocument(file: File): Promise<{ kind: DocKind; bytes: Uint8Array; paragraphs: DocParagraph[] }> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const kind = docKind(file, bytes);
  if (!kind) throw new Error('That file isn’t a PDF or a Word document.');
  if (kind === 'doc') throw new Error('This is an old Word (.doc) file. Open it in Word or Pages and save it as .docx or PDF, then import that.');
  if (kind === 'text') {
    const text = new TextDecoder().decode(bytes);
    return { kind, bytes, paragraphs: text.split(/\r?\n/).map((t, i, a) => ({ text: t, highlight: null, bold: false, gapBefore: i === 0 || !a[i - 1].trim() })) };
  }
  if (kind === 'pdf') return { kind, bytes, paragraphs: await pdfParagraphs(await loadPdfJs(), bytes) };
  const files = unzipSync(bytes, { filter: (f) => f.name === 'word/document.xml' });
  const xml = files['word/document.xml'];
  if (!xml) throw new Error('That Word file has no document text.');
  return { kind, bytes, paragraphs: docxParagraphs(new TextDecoder().decode(xml), new DOMParser()) };
}
