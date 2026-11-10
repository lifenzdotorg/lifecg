// ProPresenter 7 `.probundle` export, for campuses still building notes in ProPresenter during the changeover.
//
// A .probundle is a zip holding the `.pro` presentation (protobuf `rv.data.Presentation`, schema in
// ./propresenter) and the media it uses. Each portal slide becomes one ProPresenter slide built from the
// campus theme: the theme's background layer (Central's image, West/East's dark band) and one text box
// with the theme's font, size, tracking, line height, outline, shadow and alignment, the slide's text as
// RTF (bold runs bold). Element defaults copy LIFE's own ProPresenter 21.x exports.
import { zipSync } from 'fflate';
import * as protobuf from 'protobufjs/light';
import descriptor from './propresenter/presentation.json';
import type { Slide, Theme, ThemeStyle } from './types';

const root = protobuf.Root.fromJSON(descriptor as protobuf.INamespace);
const Presentation = root.lookupType('rv.data.Presentation');

export interface BundleMedia {
  /** file name as in the theme (e.g. background.png) */
  src: string;
  bytes: Uint8Array;
}

export interface BundleInput {
  /** presentation name, e.g. `2026 11 15 II CENTRAL PM II Erin Manners - Psalms Intro` */
  name: string;
  slides: Slide[];
  theme: Theme;
  /** image layers of the theme, by `src` */
  media?: BundleMedia[];
  uuid?: () => string;
}

const MAC = 'PLATFORM_MACOS';
const WHITE = { red: 1, green: 1, blue: 1, alpha: 1 };
// Where the media seem to live on the exporting Mac. ProPresenter copies them into its own library on
// import, using the zip entry with this path (as in its own exports).
const MEDIA_DIR = '/Users/Shared/ProPresenter/Media/Assets';

const rectanglePath = {
  closed: true,
  points: [
    { point: {}, q0: {}, q1: {} },
    { point: { x: 1 }, q0: { x: 1 }, q1: { x: 1 } },
    { point: { x: 1, y: 1 }, q0: { x: 1, y: 1 }, q1: { x: 1, y: 1 } },
    { point: { y: 1 }, q0: { y: 1 }, q1: { y: 1 } },
  ],
  shape: { type: 'TYPE_RECTANGLE' },
};

const bounds = (r: number[]) => ({ origin: { x: r[0], y: r[1] }, size: { width: r[2], height: r[3] } });

/** `rgba(0,0,0,0.30)` / `#000000` -> components 0–1 */
export function parseColour(css: string): { red: number; green: number; blue: number; alpha: number } {
  const m = /rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+))?\s*\)/i.exec(css);
  if (m) return { red: +m[1] / 255, green: +m[2] / 255, blue: +m[3] / 255, alpha: m[4] === undefined ? 1 : +m[4] };
  const h = /^#?([0-9a-f]{6})$/i.exec(css.trim());
  if (h) return { red: parseInt(h[1].slice(0, 2), 16) / 255, green: parseInt(h[1].slice(2, 4), 16) / 255, blue: parseInt(h[1].slice(4, 6), 16) / 255, alpha: 1 };
  return { red: 1, green: 1, blue: 1, alpha: 1 };
}

// ───────────────────────── RTF (what ProPresenter stores as the slide text) ─────────────────────────

function rtfEscape(s: string): string {
  let out = '';
  for (const ch of s) {
    const c = ch.codePointAt(0)!;
    if (ch === '\\' || ch === '{' || ch === '}') out += '\\' + ch;
    else if (ch === '\n') out += '\\\n';
    else if (c < 128) out += ch;
    else if (c <= 0xffff) out += `\\uc0\\u${c > 32767 ? c - 65536 : c} `;
    else {
      const v = c - 0x10000;
      for (const u of [0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff)]) out += `\\uc0\\u${u - 65536} `;
    }
  }
  return out;
}

const rgb255 = (c: { red: number; green: number; blue: number }) =>
  `\\red${Math.round(c.red * 255)}\\green${Math.round(c.green * 255)}\\blue${Math.round(c.blue * 255)}`;

/** The slide's runs as Cocoa RTF, formatted like ProPresenter's own (font, size, tracking, outline). */
export function slideRtf(slide: Slide, style: ThemeStyle, theme: Theme): string {
  const fill = parseColour(theme.text.color);
  const stroke = parseColour(theme.text.strokeColor);
  const sl = style.lineHeight !== 1 ? `\\sl${Math.round(240 * style.lineHeight)}\\slmult1` : '';
  const kern = style.tracking ? `\\kerning1\\expnd${Math.round(style.tracking * 4)}\\expndtw${Math.round(style.tracking * 20)}\n` : '';
  let body = '';
  let bold: boolean | null = null;
  for (const r of slide.runs) {
    const b = !!r.b || style.regularFont === style.boldFont;
    if (b !== bold) body += b ? '\\b ' : '\\b0 ';
    bold = b;
    body += rtfEscape(r.t);
  }
  return (
    `{\\rtf1\\ansi\\ansicpg1252\\cocoartf2870\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fnil\\fcharset0 ${style.regularFont};}\n` +
    `{\\colortbl;\\red255\\green255\\blue255;${rgb255(fill)};${rgb255(stroke)};}\n` +
    `{\\*\\expandedcolortbl;;\\cssrgb\\c${Math.round(fill.red * 1e5)}\\c${Math.round(fill.green * 1e5)}\\c${Math.round(fill.blue * 1e5)};` +
    `\\cssrgb\\c${Math.round(stroke.red * 1e5)}\\c${Math.round(stroke.green * 1e5)}\\c${Math.round(stroke.blue * 1e5)}\\c${Math.round(stroke.alpha * 1e5)};}\n` +
    `\\deftab1680\n\\pard\\pardeftab1680${sl}\\pardirnatural\\partightenfactor0\n\n` +
    `\\f0\\fs${Math.round(style.size * 2)} \\cf2 ${kern}\\outl0\\strokewidth-${Math.round(theme.text.strokePercent * 20)} \\strokec3 ${body}}`
  );
}

// ───────────────────────── Elements ─────────────────────────

const VALIGN = { top: 'VERTICAL_ALIGNMENT_TOP', middle: 'VERTICAL_ALIGNMENT_MIDDLE', bottom: 'VERTICAL_ALIGNMENT_BOTTOM' } as const;
const enc = new TextEncoder();

function textElement(slide: Slide, theme: Theme, uuid: () => string) {
  const style = theme.styles[slide.style];
  const stroke = parseColour(theme.text.strokeColor);
  const shadow = parseColour(theme.text.shadow.color);
  const fontName = slide.style === 'big' ? style.boldFont : style.regularFont;
  return {
    element: {
      uuid: { string: uuid() },
      name: 'Text',
      bounds: bounds(style.rect),
      opacity: 1,
      path: rectanglePath,
      fill: { color: { red: 0.13, green: 0.59, blue: 0.95, alpha: 1 } }, // ProPresenter's default; not enabled
      stroke: { width: 3, color: WHITE },
      shadow: { angle: 315, offset: 5, radius: 5, color: { alpha: 1 }, opacity: 0.75 },
      feather: { radius: 0.05 },
      text: {
        attributes: {
          font: { name: fontName, size: style.size, family: fontName.replace(/-[^-]*$/, '') },
          text_solid_fill: parseColour(theme.text.color),
          underline_style: {},
          paragraph_style: { line_height_multiple: style.lineHeight, default_tab_interval: 84, text_list: {} },
          kerning: style.tracking,
          strikethrough_style: {},
          stroke_width: -theme.text.strokePercent,
          stroke_color: { red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: stroke.alpha },
        },
        shadow: {
          angle: theme.text.shadow.angle,
          offset: theme.text.shadow.offset,
          radius: theme.text.shadow.blur,
          color: { red: shadow.red, green: shadow.green, blue: shadow.blue, alpha: 1 },
          opacity: shadow.alpha,
          enable: true,
        },
        rtf_data: enc.encode(slideRtf(slide, style, theme)),
        vertical_alignment: VALIGN[style.valign as keyof typeof VALIGN] ?? 'VERTICAL_ALIGNMENT_TOP',
        margins: {},
        is_superscript_standardized: true,
        transformDelimiter: '  •  ',
        chord_pro: { color: WHITE },
      },
      text_line_mask: {},
    },
    info: 3,
    text_scroller: { scroll_rate: 0.5, should_repeat: true, repeat_distance: 0.059 },
  };
}

interface MediaFile {
  path: string; // absolute, as recorded in the .pro
  bytes: Uint8Array;
  mediaUuid: string;
}

function imageElement(rect: number[], file: MediaFile, uuid: () => string) {
  return {
    element: {
      uuid: { string: uuid() },
      bounds: bounds(rect),
      opacity: 1,
      path: rectanglePath,
      fill: {
        media: {
          uuid: { string: file.mediaUuid },
          url: {
            absolute_string: 'file://' + file.path.split('/').map(encodeURIComponent).join('/'),
            platform: MAC,
            local: { root: 'ROOT_SHOW', path: 'Media/Assets/' + file.path.split('/').pop() },
          },
          metadata: { format: file.path.split('.').pop()!.toLowerCase() },
          image: { drawing: { natural_size: { width: rect[2], height: rect[3] }, custom_image_bounds: { origin: {}, size: {} }, crop_insets: {} } },
        },
        enable: true,
      },
      stroke: { width: 3, color: WHITE },
      shadow: { angle: 315, offset: 5, radius: 5, color: { alpha: 1 }, opacity: 0.75 },
      feather: { radius: 0.05 },
      text_line_mask: {},
    },
    info: 1,
    text_scroller: { scroll_rate: 0.5, should_repeat: true, repeat_distance: 0.052 },
  };
}

function shapeElement(rect: number[], colour: string, opacity: number, uuid: () => string) {
  return {
    element: {
      uuid: { string: uuid() },
      name: 'Background',
      bounds: bounds(rect),
      opacity,
      path: rectanglePath,
      fill: { color: parseColour(colour), enable: true },
      stroke: { width: 3, color: WHITE },
      shadow: { angle: 315, offset: 5, radius: 5, color: { alpha: 1 }, opacity: 0.75 },
      feather: { radius: 0.05 },
      text_line_mask: {},
    },
    info: 1,
    text_scroller: { scroll_rate: 0.5, should_repeat: true, repeat_distance: 0.052 },
  };
}

// ───────────────────────── Presentation + zip ─────────────────────────

const newUuid = () => crypto.randomUUID().toUpperCase();

/** File-safe version of the presentation name (ProPresenter shows the name from inside the file). */
export function bundleFileName(name: string): string {
  return (name.replace(/[/\\:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim() || 'Speaker Notes') + '.probundle';
}

export function buildPresentation(input: BundleInput): { pro: Uint8Array; files: MediaFile[] } {
  const uuid = input.uuid ?? newUuid;
  const { theme } = input;
  // One copy of each image for the whole presentation.
  const files: MediaFile[] = [];
  const layers = theme.layers.map((l) => {
    if (l.type === 'image') {
      const m = input.media?.find((x) => x.src === l.src);
      if (!m) throw new Error(`The theme image ${l.src} wasn’t loaded`);
      const file = { path: `${MEDIA_DIR}/${uuid()}${(l.src ?? "image.png").replace(/[^\w.-]+/g, '_')}`, bytes: m.bytes, mediaUuid: uuid() };
      files.push(file);
      return { kind: 'image' as const, rect: l.rect, file };
    }
    return { kind: 'rect' as const, rect: l.rect, colour: l.color ?? '#000000', opacity: l.opacity ?? 1 };
  });

  const cues = input.slides.map((s) => {
    // ProPresenter draws the first element on top: text, then the theme layers from top to bottom.
    const elements = [
      textElement(s, theme, uuid),
      ...[...layers].reverse().map((l) => (l.kind === 'image' ? imageElement(l.rect, l.file, uuid) : shapeElement(l.rect, l.colour, l.opacity, uuid))),
    ];
    return {
      uuid: { string: uuid() },
      completion_action_type: 'COMPLETION_ACTION_TYPE_LAST',
      hot_key: {},
      actions: [
        {
          uuid: { string: uuid() },
          isEnabled: true,
          type: 'ACTION_TYPE_PRESENTATION_SLIDE',
          slide: {
            presentation: {
              base_slide: { elements, size: { width: theme.canvas[0], height: theme.canvas[1] }, uuid: { string: uuid() } },
              chord_chart: { platform: MAC },
            },
          },
        },
      ],
      isEnabled: true,
    };
  });

  const obj = {
    application_info: {
      platform: MAC,
      platform_version: { major_version: 26, minor_version: 6, patch_version: 2 },
      application: 'APPLICATION_PROPRESENTER',
      application_version: { major_version: 21, minor_version: 4, build: '352583705' },
    },
    uuid: { string: uuid() },
    name: input.name,
    background: { color: { alpha: 1 } },
    chord_chart: { platform: MAC },
    cue_groups: [{ group: { uuid: { string: uuid() }, hotKey: {} }, cue_identifiers: cues.map((c) => ({ string: c.uuid.string })) }],
    cues,
    timeline: { duration: 300 },
  };
  const err = Presentation.verify(Presentation.fromObject(obj));
  if (err) throw new Error('ProPresenter export: ' + err);
  return { pro: Presentation.encode(Presentation.fromObject(obj)).finish(), files };
}

/** The .probundle: `<name>.pro` plus each image at its recorded path (without the leading slash). */
export function buildProBundle(input: BundleInput): { fileName: string; bytes: Uint8Array } {
  const { pro, files } = buildPresentation(input);
  const fileName = bundleFileName(input.name);
  const entries: Record<string, Uint8Array> = { [fileName.replace(/\.probundle$/, '.pro')]: pro };
  for (const f of files) entries[f.path.replace(/^\//, '')] = f.bytes;
  return { fileName, bytes: zipSync(entries, { level: 0 }) };
}

/** Decodes a .pro (for tests and checks). */
export function decodePresentation(pro: Uint8Array): Record<string, unknown> {
  return Presentation.toObject(Presentation.decode(pro), { enums: String, longs: String, defaults: false }) as Record<string, unknown>;
}
