import { describe, expect, it } from 'vitest';
import { controlReturnUrl } from '../src/worker/operator';

describe('operator sign-in return URL', () => {
  it('accepts a CG Mac control page on the local network', () => {
    for (const u of ['http://192.168.1.20:9300/control', 'http://10.0.4.7/control/', 'http://172.20.1.1:9300/control', 'http://cg-central.local:9300/control', 'http://localhost:9300/control', 'http://127.0.0.1:9300/control?x=1#y']) {
      const r = controlReturnUrl(u);
      expect(r, u).not.toBeNull();
      expect(r!.search + r!.hash).toBe('');
    }
  });
  it('refuses anything that could hand the code to another site', () => {
    for (const u of [undefined, '', 'https://evil.example/control', 'http://8.8.8.8/control', 'http://172.32.0.1/control', 'http://192.168.1.20/other',
      'javascript:alert(1)', 'http://user:pw@192.168.1.20/control', 'http://192.168.1.20.evil.example/control', 'http://evil.local.example.com/control', 'ftp://10.0.0.1/control', 'http://300.1.1.1/control']) {
      expect(controlReturnUrl(u), String(u)).toBeNull();
    }
  });
});

import { emailRecipients } from '../src/worker/index';
describe('push email recipients', () => {
  it('puts the campus list and speaker in To and the notes creator in Cc', () => {
    expect(emailRecipients(['PM@lifenz.org', 'graphics@lifenz.org'], 'speaker@example.com', ['pa@lifenz.org', 'pa@lifenz.org'])).toEqual({
      to: ['pm@lifenz.org', 'graphics@lifenz.org', 'speaker@example.com'],
      cc: ['pa@lifenz.org'],
    });
  });
  it('copies the pusher too when someone else pushed, and never lists anyone twice', () => {
    expect(emailRecipients(['pm@lifenz.org'], null, ['pa@lifenz.org', 'pm@lifenz.org'])).toEqual({ to: ['pm@lifenz.org'], cc: ['pa@lifenz.org'] });
  });
  it('sends To the creator when there is nobody else', () => {
    expect(emailRecipients([], null, ['pa@lifenz.org'])).toEqual({ to: ['pa@lifenz.org'], cc: [] });
  });
});

import { buildEmail } from '../src/worker/email';
describe('push email attachments', () => {
  it('are the exact bytes, not base64 text (Outlook saved a .probundle full of "UEsDB…")', () => {
    const zip = new Uint8Array([0x50, 0x4b, 0x03, 0x04, 1, 2, 3]);
    const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d]);
    const msg = buildEmail({} as never, {
      to: ['pm@lifenz.org'], title: 'T', speaker: 'S', serviceLabel: 'Central AM', startsAt: '2026-11-15T09:30:00+13:00', version: 1,
      pushedBy: 'pa@lifenz.org', slideCount: 3, portalUrl: 'https://notes.example/', pdf, pdfName: 'a.pdf',
      probundle: { bytes: zip, name: 'a.probundle' }, notes: { bytes: pdf, name: 'n.pdf', type: 'application/pdf' },
    });
    expect(msg.attachments.map((a) => a.content)).toEqual([pdf, zip, pdf]);
    expect(msg.attachments[1]).toMatchObject({ filename: 'a.probundle', type: 'application/octet-stream' });
  });
});
