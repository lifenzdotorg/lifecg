import { readFileSync } from 'node:fs';
import { unzipSync } from 'fflate';
import { describe, expect, it } from 'vitest';
import { buildProBundle, decodePresentation, slideRtf } from '../shared/probundle';
import { THEMES } from '../shared/themes';
import type { Slide } from '../shared/types';

const slides: Slide[] = [
  { id: 'a', kind: 'scripture', style: 'small', runs: [{ t: 'Psalm 1 (NIV)', b: true }, { t: '\n1 Blessed is the one who does not walk in step with the wicked or stand in the way that sinners take or sit in the company of mockers,' }] },
  { id: 'b', kind: 'point', style: 'big', runs: [{ t: 'What I’m rooted in will shape who I become', b: true }] },
];
const background = new Uint8Array(readFileSync('../notes-themes/central/background.png'));

describe('.probundle export', () => {
  it('builds a Central bundle with the background image inside', () => {
    const { fileName, bytes } = buildProBundle({
      name: '2026 11 15 II CENTRAL PM II Erin Manners - Psalms Intro',
      slides,
      theme: THEMES.central,
      media: [{ src: 'background.png', bytes: background }],
    });
    expect(fileName).toBe('2026 11 15 II CENTRAL PM II Erin Manners - Psalms Intro.probundle');
    const files = unzipSync(bytes);
    const names = Object.keys(files);
    expect(names).toContain('2026 11 15 II CENTRAL PM II Erin Manners - Psalms Intro.pro');
    const imageEntry = names.find((n) => n.endsWith('background.png'))!;
    expect(files[imageEntry].byteLength).toBe(background.byteLength);

    const p = decodePresentation(files['2026 11 15 II CENTRAL PM II Erin Manners - Psalms Intro.pro']) as any;
    expect(p.name).toBe('2026 11 15 II CENTRAL PM II Erin Manners - Psalms Intro');
    expect(p.cues).toHaveLength(2);
    expect(p.cue_groups[0].cue_identifiers.map((c: any) => c.string)).toEqual(p.cues.map((c: any) => c.uuid.string));
    const els = p.cues[0].actions[0].slide.presentation.base_slide.elements;
    expect(els[0].element.name).toBe('Text');
    expect(els[0].element.bounds.origin.y).toBeCloseTo(753.138, 2);
    expect(els[0].element.text.vertical_alignment).toBe('VERTICAL_ALIGNMENT_BOTTOM');
    expect(els[0].element.text.attributes.font).toMatchObject({ name: 'NeuzeitGro-Reg', size: 54 });
    const media = els[1].element.fill.media;
    // the .pro points at the image by the same path as its zip entry
    expect(decodeURIComponent(media.url.absolute_string)).toBe('file:///' + imageEntry);
    expect(media.url.local).toMatchObject({ root: 'ROOT_SHOW', path: 'Media/Assets/' + imageEntry.split('/').pop() });
    const big = p.cues[1].actions[0].slide.presentation.base_slide.elements[0].element;
    expect(big.bounds.origin.y).toBeCloseTo(953.637, 2);
    expect(big.text.attributes.font).toMatchObject({ name: 'NeuzeitGro-Bol', size: 75 });
  });

  it('writes the text as RTF like ProPresenter (bold heading, NBSP, curly quotes)', () => {
    const t = THEMES.central;
    const small = slideRtf(slides[0], t.styles.small, t);
    expect(small).toContain('\\fs108 \\cf2 \\kerning1\\expnd8\\expndtw40');
    expect(small).toContain('\\sl216\\slmult1');
    expect(small).toContain('\\strokewidth-40 \\strokec3 \\b Psalm 1 (NIV)\\b0 \\\n1 Blessed');
    expect(small).toContain('of\\uc0\\u160 mockers,');
    const big = slideRtf(slides[1], t.styles.big, t);
    expect(big).toContain('\\fs150');
    expect(big).not.toContain('\\sl');
    expect(big).toContain('What I\\uc0\\u8217 m rooted');
  });

  it('builds every theme; West and East with background get their dark band', () => {
    for (const t of Object.values(THEMES)) {
      const { bytes } = buildProBundle({ name: 'Test', slides, theme: t, media: [{ src: 'background.png', bytes: background }] });
      const files = unzipSync(bytes);
      const p = decodePresentation(files['Test.pro']) as any;
      const els = p.cues[0].actions[0].slide.presentation.base_slide.elements;
      expect(els.length, t.id).toBe(1 + t.layers.length);
      if (t.id === 'west' || t.id === 'east-bg') {
        expect(els[1].element.fill.enable).toBe(true);
        expect(els[1].element.opacity).toBeLessThan(0.6);
      }
    }
  });

  it('decodes LIFE’s own ProPresenter export with the same schema (format check)', () => {
    // A .pro extracted from a real export (not in the repo: sermon content); runs only where it's given.
    // (ProPresenter's zips use headers fflate misreads, so extract them with \`unzip\` first.)
    const f = process.env.PRO_SAMPLE;
    if (!f) return;
    const p = decodePresentation(new Uint8Array(readFileSync(f))) as any;
    expect(p.cues.length).toBeGreaterThan(0);
    expect(p.cues[0].actions[0].slide.presentation.base_slide.elements[0].element.text.rtf_data).toBeTruthy();
  });
});
