// PDF email via the Cloudflare Email Service `send_email` binding.
import { formatServiceDate } from '../../shared/time';
import type { Bindings } from './env';

export interface NotesEmail {
  to: string[];
  cc?: string[];
  title: string;
  speaker: string;
  serviceLabel: string; // "Central AM"
  startsAt: string;
  version: number;
  pushedBy: string;
  slideCount: number;
  portalUrl: string;
  pdf: Uint8Array;
  pdfName: string;
  /** the speaker's full notes, attached as "Notes" */
  notes?: { bytes: Uint8Array; name: string; type: string } | null;
  /** when the notes are too big to attach: a portal link instead */
  notesLink?: string | null;
  /** ProPresenter 7 bundle for campuses still on the legacy setup */
  probundle?: { bytes: Uint8Array; name: string } | null;
  probundleLink?: string | null;
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

export function buildEmail(env: Bindings, e: NotesEmail) {
  const when = formatServiceDate(e.startsAt);
  const updated = e.version > 1;
  const subject = `${updated ? 'Updated speaker notes' : 'Speaker notes'}: ${e.title || 'Untitled'}, ${e.serviceLabel} ${when}`;
  const lines = [
    updated ? `The speaker notes for ${e.serviceLabel}, ${when} have been updated (version ${e.version}).` : `Speaker notes for ${e.serviceLabel}, ${when}.`,
    '',
    `Message: ${e.title}`,
    `Speaker: ${e.speaker}`,
    `Slides: ${e.slideCount}`,
    `Pushed by: ${e.pushedBy}`,
    '',
    'Slides Preview (attached): the rendered slides and their text.',
    ...(e.probundle ? ['ProPresenter (attached): import the .probundle file into ProPresenter 7.'] : []),
    ...(e.probundleLink ? [`ProPresenter: the .probundle is too large to attach. Download: ${e.probundleLink}`] : []),
    ...(e.notes ? ['Notes (attached): the speaker’s full notes, to follow along.'] : []),
    ...(e.notesLink ? [`Notes: the speaker’s full notes are too large to attach. Download: ${e.notesLink}`] : []),
    `Portal: ${e.portalUrl}`,
  ];
  const html = `<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1d1d1f">
<p>${esc(lines[0])}</p>
<table style="border-collapse:collapse;margin:12px 0">
${[['Message', e.title], ['Speaker', e.speaker], ['Slides', String(e.slideCount)], ['Pushed by', e.pushedBy]]
  .map(([k, v]) => `<tr><td style="color:#6e6e73;padding:2px 16px 2px 0">${k}</td><td>${esc(v)}</td></tr>`)
  .join('\n')}
</table>
<p><b>Slides Preview</b> (attached): the rendered slides and their text.</p>
${e.probundle ? '<p><b>ProPresenter</b> (attached): import the .probundle file into ProPresenter 7.</p>' : ''}
${e.probundleLink ? `<p><b>ProPresenter</b>: the .probundle is too large to attach. <a href="${esc(e.probundleLink)}">Download it from the portal</a>.</p>` : ''}
${e.notes ? '<p><b>Notes</b> (attached): the speaker’s full notes, to follow along.</p>' : ''}
${e.notesLink ? `<p><b>Notes</b>: the speaker’s full notes are too large to attach. <a href="${esc(e.notesLink)}">Download them from the portal</a>.</p>` : ''}
<p><a href="${esc(e.portalUrl)}">Open the notes portal</a></p>
</div>`;
  return {
    to: e.to,
    ...(e.cc?.length ? { cc: e.cc } : {}),
    from: { email: env.EMAIL_FROM || 'notes@prodapps.life', name: env.EMAIL_FROM_NAME || 'LIFE Speaker Notes' },
    subject,
    text: lines.join('\n'),
    html,
    attachments: [
      // Raw bytes. (A base64 string arrived as base64 *text* for non-PDF types: Outlook saved a .probundle
      // full of `UEsDB…`. The local simulator can't send binary, but local dev runs with EMAIL_DRY_RUN=1.)
      { content: e.pdf, filename: e.pdfName, type: 'application/pdf', disposition: 'attachment' as const },
      // A .probundle is a zip inside, but labelled as one, mail apps and attachment scanners unpack or rewrap it.
      ...(e.probundle ? [{ content: e.probundle.bytes, filename: e.probundle.name, type: 'application/octet-stream', disposition: 'attachment' as const }] : []),
      ...(e.notes ? [{ content: e.notes.bytes, filename: e.notes.name, type: e.notes.type, disposition: 'attachment' as const }] : []),
    ],
  };
}

export async function sendNotesEmail(env: Bindings, e: NotesEmail): Promise<{ sent: boolean; dryRun: boolean; subject: string; messageId?: string }> {
  const msg = buildEmail(env, e);
  if (env.EMAIL_DRY_RUN === '1' || !env.EMAIL) {
    console.log(
      `[email dry run] from=${msg.from.email} to=${msg.to.join(', ')}${e.cc?.length ? ` cc=${e.cc.join(', ')}` : ''} subject="${msg.subject}" attachments=${e.pdfName} (${e.pdf.byteLength} bytes)${e.probundle ? `, ${e.probundle.name} (${e.probundle.bytes.byteLength} bytes)` : ''}${e.notes ? `, ${e.notes.name} (${e.notes.bytes.byteLength} bytes)` : ''}${e.notesLink ? ` notesLink=${e.notesLink}` : ''}`,
    );
    return { sent: false, dryRun: true, subject: msg.subject };
  }
  const res = await env.EMAIL.send(msg);
  return { sent: true, dryRun: false, subject: msg.subject, messageId: res.messageId };
}
