import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks';
import { mergeSlides, nextSlideId, splitSlideAt } from '../../../shared/edit';
import { wrapRuns, wrapWidth } from '../../../shared/layout';
import { markupToRuns, runsToMarkup } from '../../../shared/markup';
import { parseBlocks } from '../../../shared/parse';
import { buildSlides, fixOrphans, type SplitContext } from '../../../shared/split';
import { previewCrop, splitStyle, THEMES } from '../../../shared/themes';
import { formatServiceDate } from '../../../shared/time';
import type { Block, Measure, Slide, SlideKind, StyleName } from '../../../shared/types';
import { slideWarnings } from '../../../shared/warnings';
import { highlightSummary, type DocParagraph, type HighlightSummary, paragraphsToSource } from '../../../shared/docimport';
import { api } from '../api';
import { readDocument } from '../importDoc';
import { renderSlide } from '../render';
import { getPreviewTheme, type RenderKit, setPreviewTheme, useRenderKit } from '../state';
import { PushDialog } from './Push';

interface Message {
  id: string;
  title: string;
  speaker: string;
  speakerEmail: string | null;
  createdBy: string;
  updatedAt: string;
  sourceText: string;
  blocks: Block[];
  slides: Slide[];
  notesFile: { name: string; type: string; size: number } | null;
}

interface PushedService {
  id: string;
  label: string;
  startsAt: string;
  version: number;
  messageId: string;
}

export function splitContext(measure: Measure): SplitContext {
  const s = splitStyle('small');
  const b = splitStyle('big');
  return { measure, small: { ...s, width: wrapWidth(s.rect[2]) }, big: { ...b, width: wrapWidth(b.rect[2]) } };
}

export function EditorPage({ id }: { id: string }) {
  const [msg, setMsg] = useState<Message | null>(null);
  const [services, setServices] = useState<PushedService[]>([]);
  const [dirty, setDirty] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [themeId, setThemeId] = useState(getPreviewTheme());
  const [pushing, setPushing] = useState(false);
  const { kit, error: kitError } = useRenderKit(themeId);

  const load = () =>
    api<{ message: Message; services: PushedService[] }>(`/messages/${id}`).then(
      (r) => {
        setMsg(r.message);
        setServices(r.services);
      },
      (e) => setErr(e.message),
    );
  useEffect(() => {
    load();
  }, [id]);

  useEffect(() => {
    const warn = (e: BeforeUnloadEvent) => {
      if (dirty) e.preventDefault();
    };
    addEventListener('beforeunload', warn);
    return () => removeEventListener('beforeunload', warn);
  }, [dirty]);

  if (err) return <section class="page"><p class="error">{err}</p></section>;
  if (!msg) return <section class="page"><p class="muted">Loading…</p></section>;

  const update = (patch: Partial<Message> | ((m: Message) => Partial<Message>)) => {
    setMsg((m) => (m ? { ...m, ...(typeof patch === 'function' ? patch(m) : patch) } : m));
    setDirty(true);
  };
  /** Slide edits always apply to the latest list (several can land before a re-render). */
  const editSlides = (f: (slides: Slide[]) => Slide[]) => update((m) => ({ slides: f(m.slides) }));

  const save = async (): Promise<boolean> => {
    setStatus('Saving…');
    try {
      await api(`/messages/${msg.id}`, {
        method: 'PUT',
        body: { title: msg.title, speaker: msg.speaker, speakerEmail: msg.speakerEmail, sourceText: msg.sourceText, blocks: msg.blocks, slides: msg.slides.map(fixOrphans) },
      });
      setDirty(false);
      setStatus('Saved');
      setTimeout(() => setStatus(null), 2000);
      return true;
    } catch (e) {
      setStatus(null);
      alert((e as Error).message);
      return false;
    }
  };

  const build = (sourceText = msg.sourceText, ask = true) => {
    if (!kit) return;
    if (ask && msg.slides.length && !confirm('Rebuild all slides from the notes text? Your slide edits will be replaced.')) return;
    const blocks = parseBlocks(sourceText);
    update({ sourceText, blocks, slides: buildSlides(blocks, splitContext(kit.fonts.measure)) });
  };

  /** Import (text from a PDF / Word file) replaces the text box and rebuilds the slides. */
  const applyImport = (text: string) => {
    if (msg.slides.length && !confirm('Replace the slide text and rebuild all slides from the imported document?')) return false;
    build(text, false);
    return true;
  };

  const openPush = async () => {
    if (dirty && !(await save())) return;
    setPushing(true);
  };

  const pickTheme = (t: string) => {
    setThemeId(t);
    setPreviewTheme(t);
  };

  return (
    <section class="page editor">
      <div class="page-head">
        <h1>
          <a href="#/messages" class="back" aria-label="Back to messages">
            ‹
          </a>
          {msg.title || 'Untitled message'}
        </h1>
        <div class="actions">
          {status && <span class="muted">{status}</span>}
          {dirty && !status && <span class="muted">Unsaved changes</span>}
          <button onClick={save} disabled={!dirty}>
            Save
          </button>
          <button class="primary" onClick={openPush} disabled={!msg.slides.length}>
            Push…
          </button>
        </div>
      </div>

      <div class="meta-grid">
        <label>
          Title
          <input value={msg.title} onInput={(e) => update({ title: e.currentTarget.value })} placeholder="Fresh Oil" />
        </label>
        <label>
          Speaker
          <input value={msg.speaker} onInput={(e) => update({ speaker: e.currentTarget.value })} placeholder="Speaker name" />
        </label>
        <label>
          Speaker email
          <input type="email" value={msg.speakerEmail ?? ''} onInput={(e) => update({ speakerEmail: e.currentTarget.value || null })} placeholder="Gets the PDF on push" />
        </label>
      </div>

      {services.length > 0 && (
        <div class="pushed-to">
          Pushed to:{' '}
          {services.map((s) => (
            <span class="chip" key={s.id}>
              {s.label} {formatServiceDate(s.startsAt)} · v{s.version}
              {s.messageId !== msg.id && ' (replaced)'}
            </span>
          ))}
        </div>
      )}

      <div class="editor-cols">
        <div class="source">
          <div class="source-head">
            <h2>Slide text</h2>
            <DocImport messageId={msg.id} hasNotesFile={!!msg.notesFile} onText={applyImport} onNotesFile={(f) => setMsg((m) => (m ? { ...m, notesFile: f } : m))} />
          </div>
          <p class="hint">
            Paste the slide text, or import it from the speaker’s PDF or Word document. Separate items with a blank line. A first line like{' '}
            <code>John 4:4-10 (NLT)</code> or <code>Psalm 1 NIV</code> makes a scripture, a leading quote mark a quote, anything else a point.
          </p>
          <textarea class="source-text" value={msg.sourceText} onInput={(e) => update({ sourceText: e.currentTarget.value })} spellcheck />
          <button class="primary wide" onClick={() => build()} disabled={!kit || !msg.sourceText.trim()}>
            {kit ? 'Build slides' : 'Loading fonts…'}
          </button>
          {kitError && <p class="error">{kitError}</p>}
          <NotesFileCard messageId={msg.id} file={msg.notesFile} onChange={(f) => setMsg((m) => (m ? { ...m, notesFile: f } : m))} />
        </div>

        <div class="slides">
          <div class="slides-head">
            <h2>
              Slides <span class="muted">{msg.slides.length}</span>
            </h2>
            <label class="inline">
              Preview theme
              <select value={themeId} onChange={(e) => pickTheme(e.currentTarget.value)}>
                {Object.values(THEMES).map((t) => (
                  <option value={t.id}>{t.name}</option>
                ))}
              </select>
            </label>
          </div>
          {!msg.slides.length && <p class="empty">No slides yet. Paste the notes and press “Build slides”.</p>}
          {kit &&
            msg.slides.map((s, i) => (
              <SlideCard
                key={s.id}
                slide={s}
                index={i}
                kit={kit}
                isLast={i === msg.slides.length - 1}
                onChange={(n) => editSlides((sl) => sl.map((x) => (x.id === s.id ? n : x)))}
                onSplit={(markup, pos) =>
                  editSlides((sl) => {
                    const k = sl.findIndex((x) => x.id === s.id);
                    const [a, b] = splitSlideAt({ ...sl[k], runs: markupToRuns(markup) }, markup, pos, nextSlideId(sl, s.id));
                    return [...sl.slice(0, k), a, b, ...sl.slice(k + 1)];
                  })
                }
                onMerge={() =>
                  editSlides((sl) => {
                    const k = sl.findIndex((x) => x.id === s.id);
                    return k < sl.length - 1 ? [...sl.slice(0, k), mergeSlides(sl[k], sl[k + 1]), ...sl.slice(k + 2)] : sl;
                  })
                }
                onDelete={() => editSlides((sl) => sl.filter((x) => x.id !== s.id))}
                onAdd={() =>
                  editSlides((sl) => {
                    const k = sl.findIndex((x) => x.id === s.id);
                    const heading = s.kind === 'scripture' && s.runs[0]?.b ? s.runs[0].t.split('\n')[0] : null;
                    const n: Slide = {
                      id: nextSlideId(sl, s.id),
                      kind: s.kind,
                      style: 'small',
                      runs: heading ? [{ t: heading, b: true }, { t: '\n' }] : [{ t: 'NEW POINT', b: true }],
                    };
                    return [...sl.slice(0, k + 1), n, ...sl.slice(k + 1)];
                  })
                }
              />
            ))}
          {msg.slides.length > 0 && (
            <div class="slides-foot">
              <button onClick={save} disabled={!dirty}>
                Save
              </button>
            </div>
          )}
        </div>
      </div>
      {pushing && (
        <PushDialog
          messageId={msg.id}
          onClose={(pushed) => {
            setPushing(false);
            if (pushed) load();
          }}
        />
      )}
    </section>
  );
}

interface CardProps {
  slide: Slide;
  index: number;
  kit: RenderKit;
  isLast: boolean;
  onChange: (s: Slide) => void;
  onSplit: (markup: string, pos: number) => void;
  onMerge: () => void;
  onDelete: () => void;
  onAdd: () => void;
}

function SlideCard({ slide, index, kit, isLast, onChange, onSplit, onMerge, onDelete, onAdd }: CardProps) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const ta = useRef<HTMLTextAreaElement>(null);
  const markup = useMemo(() => runsToMarkup(slide.runs), [slide.runs]);
  const style = kit.theme.styles[slide.style];
  const lineCount = useMemo(() => wrapRuns(slide.runs, wrapWidth(style.rect[2]), style, kit.fonts.measure).length, [slide.runs, style, kit]);
  const warnings = slideWarnings(slide, lineCount, style.maxLines);

  // keep the textarea uncontrolled while typing so the caret never jumps
  useLayoutEffect(() => {
    const el = ta.current!;
    if (el.value !== markup) el.value = markup;
    el.style.height = 'auto';
    el.style.height = `${el.scrollHeight + 2}px`;
  }, [markup]);

  useEffect(() => {
    const id = requestAnimationFrame(() => {
      if (canvas.current) renderSlide(canvas.current, kit.theme, slide, kit.fonts, kit.imgs, { scale: 0.5, crop: previewCrop(kit.theme) });
    });
    return () => cancelAnimationFrame(id);
  }, [slide, kit]);

  const onInput = (e: Event) => {
    const v = (e.currentTarget as HTMLTextAreaElement).value;
    onChange({ ...slide, runs: markupToRuns(v) });
  };

  const toggleBold = () => {
    const el = ta.current!;
    const { selectionStart: a, selectionEnd: b, value } = el;
    const sel = value.slice(a, b);
    let v: string;
    if (sel.startsWith('**') && sel.endsWith('**') && sel.length >= 4) v = value.slice(0, a) + sel.slice(2, -2) + value.slice(b);
    else if (value.slice(a - 2, a) === '**' && value.slice(b, b + 2) === '**') v = value.slice(0, a - 2) + sel + value.slice(b + 2);
    else v = value.slice(0, a) + `**${sel}**` + value.slice(b);
    el.value = v;
    onChange({ ...slide, runs: markupToRuns(v) });
    el.focus();
  };

  const setKind = (kind: SlideKind) => onChange({ ...slide, kind });
  const setStyle = (st: StyleName) => onChange(fixOrphans({ ...slide, style: st }));

  return (
    <article class={`slide-card ${warnings.length ? 'has-warn' : ''}`}>
      <div class="slide-num">{index + 1}</div>
      <canvas ref={canvas} class="preview" aria-label={`Slide ${index + 1} preview`} />
      <div class="slide-body">
        <textarea
          ref={ta}
          class="slide-text"
          onInput={onInput}
          onBlur={() => {
            const f = fixOrphans(slide);
            if (JSON.stringify(f.runs) !== JSON.stringify(slide.runs)) onChange(f);
          }}
          rows={3}
          spellcheck
          aria-label={`Slide ${index + 1} text`}
        />
        <div class="slide-tools">
          <select value={slide.kind} onChange={(e) => setKind(e.currentTarget.value as SlideKind)} aria-label="Kind">
            <option value="scripture">Scripture</option>
            <option value="point">Point</option>
            <option value="quote">Quote</option>
          </select>
          <select value={slide.style} onChange={(e) => setStyle(e.currentTarget.value as StyleName)} aria-label="Style">
            <option value="small">Small</option>
            <option value="big">Big</option>
          </select>
          <button onClick={toggleBold} title="Bold the selection (**text**)">
            <b>B</b>
          </button>
          <button onClick={() => onSplit(ta.current!.value, ta.current!.selectionStart)} title="Split this slide at the cursor">
            Split at cursor
          </button>
          <button onClick={onMerge} disabled={isLast} title="Merge with the next slide">
            Merge ↓
          </button>
          <button onClick={onAdd} title="Add a slide after this one">
            + Add
          </button>
          <button class="danger-text" onClick={onDelete} title="Delete this slide">
            Delete
          </button>
          <span class="muted small lines">
            {lineCount} / {style.maxLines} lines
          </span>
        </div>
        {slide.kind === 'point' && <PointSizeChooser slide={slide} kit={kit} onPick={setStyle} />}
        {warnings.length > 0 && (
          <ul class="warnings">
            {warnings.map((w) => (
              <li>{w.message}</li>
            ))}
          </ul>
        )}
      </div>
    </article>
  );
}

/** Point slides: show the point rendered big and small side by side so the PA can pick. Big is the
 *  default when it fits on one line; small keeps a run of points consistent when others are long. */
function PointSizeChooser({ slide, kit, onPick }: { slide: Slide; kit: RenderKit; onPick: (s: StyleName) => void }) {
  const refs = { big: useRef<HTMLCanvasElement>(null), small: useRef<HTMLCanvasElement>(null) };
  const big = kit.theme.styles.big;
  const bigFits = useMemo(
    () => wrapRuns(slide.runs, wrapWidth(big.rect[2]), big, kit.fonts.measure).length <= big.maxLines,
    [slide.runs, big, kit],
  );
  useEffect(() => {
    const id = requestAnimationFrame(() => {
      for (const st of ['big', 'small'] as StyleName[]) {
        const c = refs[st].current;
        if (c) renderSlide(c, kit.theme, { ...slide, style: st }, kit.fonts, kit.imgs, { scale: 0.25, crop: previewCrop(kit.theme) });
      }
    });
    return () => cancelAnimationFrame(id);
  }, [slide.runs, kit]);
  return (
    <div class="size-chooser" role="group" aria-label="Point size">
      {(['big', 'small'] as StyleName[]).map((st) => (
        <button
          class={`size-option ${slide.style === st ? 'on' : ''}`}
          disabled={st === 'big' && !bigFits}
          onClick={() => onPick(st)}
          title={st === 'big' && !bigFits ? 'Too long for one line at the big size' : `Use the ${st} size`}
        >
          <canvas ref={refs[st]} />
          <span>
            {st === 'big' ? 'Big' : 'Small'}
            {st === 'big' && !bigFits ? ' (too long)' : ''}
          </span>
        </button>
      ))}
    </div>
  );
}

// ───────────────────────── Import from PDF / Word, and the full "Notes" file ─────────────────────────

type NotesFile = Message['notesFile'];

const SWATCH: Record<string, string> = {
  yellow: '#ffef3a', green: '#3ee05b', cyan: '#3fe6f0', magenta: '#f05ef0', blue: '#5b7cff', red: '#ff5a4f', 'dark yellow': '#a39a1c',
  'dark green': '#2e8b3a', teal: '#1f8f8f', 'dark blue': '#2b3d9e', 'dark red': '#9e2b2b', violet: '#8b3a9e', orange: '#ffa53a', pink: '#ffc0cb',
};

async function uploadNotes(messageId: string, file: File): Promise<NotesFile> {
  const r = await api<{ notesFile: NotesFile }>(`/messages/${messageId}/notes`, {
    method: 'PUT',
    raw: file,
    contentType: file.type || 'application/octet-stream',
    headers: { 'X-File-Name': encodeURIComponent(file.name) },
  });
  return r.notesFile;
}

const fileSize = (n: number) => (n > 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`);

function DocImport(props: { messageId: string; hasNotesFile: boolean; onText: (text: string) => boolean; onNotesFile: (f: NotesFile) => void }) {
  const input = useRef<HTMLInputElement>(null);
  const [doc, setDoc] = useState<{ file: File; paragraphs: DocParagraph[]; colours: HighlightSummary[] } | null>(null);
  const [picked, setPicked] = useState<string[] | null>(null); // null = everything
  const [attach, setAttach] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const choose = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    setBusy('Reading ' + file.name + '…');
    try {
      const { paragraphs } = await readDocument(file);
      const colours = highlightSummary(paragraphs);
      // Examples and stories are often highlighted too (cyan in LIFE's notes): leave cyan off by default.
      setPicked(colours.length ? colours.map((c) => c.colour).filter((c) => c !== 'cyan') : null);
      setAttach(!props.hasNotesFile);
      setDoc({ file, paragraphs, colours });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
      if (input.current) input.current.value = '';
    }
  };

  const text = doc ? paragraphsToSource(doc.paragraphs, picked) : '';
  const run = async () => {
    if (!doc) return;
    if (!text.trim()) return setError('Nothing to import with those choices.');
    if (!props.onText(text)) return;
    if (attach) {
      setBusy('Uploading the full notes…');
      try {
        props.onNotesFile(await uploadNotes(props.messageId, doc.file));
      } catch (e) {
        setError('Imported the text, but the notes file didn’t upload: ' + (e as Error).message);
      }
      setBusy(null);
    }
    setDoc(null);
  };

  return (
    <>
      <button class="small-btn" onClick={() => input.current?.click()} disabled={!!busy}>
        Import PDF or Word…
      </button>
      <input
        ref={input}
        type="file"
        accept=".pdf,.docx,.txt,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document,text/plain"
        hidden
        onChange={(e) => choose(e.currentTarget.files?.[0])}
      />
      {(busy || error || doc) && (
        <div class="import-panel">
          {busy && <p class="muted">{busy}</p>}
          {error && <p class="error">{error}</p>}
          {doc && !busy && (
            <>
              <p>
                <b>{doc.file.name}</b>
              </p>
              {doc.colours.length ? (
                <>
                  <p class="hint">Highlighted text found. Import the colours used for slides:</p>
                  {doc.colours.map((c) => (
                    <label class="colour-row" key={c.colour}>
                      <input
                        type="checkbox"
                        checked={picked?.includes(c.colour) ?? false}
                        onChange={(e) => {
                          const on = e.currentTarget.checked;
                          setPicked((p) => (on ? [...(p ?? []), c.colour] : (p ?? []).filter((x) => x !== c.colour)));
                        }}
                      />
                      <span class="swatch" style={{ background: SWATCH[c.colour] ?? '#ccc' }} />
                      <span>
                        {c.colour} <span class="muted">({c.count} lines)</span>
                        <br />
                        <span class="muted small">“{c.sample}”</span>
                      </span>
                    </label>
                  ))}
                  <label class="colour-row">
                    <input type="checkbox" checked={picked === null} onChange={(e) => setPicked(e.currentTarget.checked ? null : doc.colours.map((c) => c.colour))} />
                    <span>Everything, ignoring highlights</span>
                  </label>
                </>
              ) : (
                <p class="hint">No highlighted text found: all of the document’s text will be imported for you to trim.</p>
              )}
              <details>
                <summary class="muted small">Preview ({text.split(/\n\s*\n/).filter((x) => x.trim()).length} items)</summary>
                <pre class="import-preview">{text}</pre>
              </details>
              <label class="colour-row">
                <input type="checkbox" checked={attach} onChange={(e) => setAttach(e.currentTarget.checked)} />
                <span>
                  Also keep this file as the full <b>Notes</b> (sent with each push)
                </span>
              </label>
              <div class="row-actions">
                <button class="primary" onClick={run}>
                  Import and build slides
                </button>
                <button onClick={() => setDoc(null)}>Cancel</button>
              </div>
            </>
          )}
          {error && !doc && (
            <div class="row-actions">
              <button onClick={() => setError(null)}>OK</button>
            </div>
          )}
        </div>
      )}
    </>
  );
}

function NotesFileCard(props: { messageId: string; file: NotesFile; onChange: (f: NotesFile) => void }) {
  const input = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const pick = async (file: File | undefined) => {
    if (!file) return;
    setBusy(true);
    try {
      props.onChange(await uploadNotes(props.messageId, file));
    } catch (e) {
      alert((e as Error).message);
    } finally {
      setBusy(false);
      if (input.current) input.current.value = '';
    }
  };
  const remove = async () => {
    if (!confirm('Remove the full notes file from this message?')) return;
    await api(`/messages/${props.messageId}/notes`, { method: 'DELETE' }).then(() => props.onChange(null), (e) => alert(e.message));
  };
  return (
    <div class="notes-file">
      <h3>Notes</h3>
      <p class="hint">The speaker’s full notes (PDF or Word), so the team can follow along. Sent with each push next to the Slides Preview.</p>
      {props.file ? (
        <div class="notes-file-row">
          <a href={`/api/messages/${props.messageId}/notes`} target="_blank" rel="noopener">
            {props.file.name}
          </a>
          <span class="muted small">{fileSize(props.file.size)}</span>
          <button class="link" onClick={() => input.current?.click()} disabled={busy}>
            Replace…
          </button>
          <button class="link danger" onClick={remove} disabled={busy}>
            Remove
          </button>
        </div>
      ) : (
        <button class="small-btn" onClick={() => input.current?.click()} disabled={busy}>
          {busy ? 'Uploading…' : 'Upload notes…'}
        </button>
      )}
      <input
        ref={input}
        type="file"
        accept=".pdf,.docx,.doc,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        hidden
        onChange={(e) => pick(e.currentTarget.files?.[0])}
      />
    </div>
  );
}
