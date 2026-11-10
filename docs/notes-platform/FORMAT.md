# Notes platform: shared formats

The contract between the portal (`cloud/`) and the Mac app (`app/`). Both sides must follow it exactly.

## Notes theme (`notes-themes/<id>/theme.json`)

All coordinates are in a 1920×1080 canvas, origin top-left, in points (= pixels at 1080p).

| Field | Meaning |
|---|---|
| `layers[]` | Drawn first, in order. `{"type":"image","src":"background.png","rect":[x,y,w,h]}` or `{"type":"rect","rect":[…],"color":"#000000","opacity":0.497}` |
| `text.color` | Fill colour of all text |
| `text.strokePercent`, `text.strokeColor` | Outline drawn *with* the fill, Cocoa `NSStrokeWidth` semantics: stroke width = `size × strokePercent / 100`, centred on the glyph outline. Canvas: `lineWidth = size*strokePercent/100`, `strokeText` then `fillText`. |
| `text.shadow` | `angle` 270 = straight down (Cocoa/ProPresenter convention: 270° points down), `offset` px, `blur` px (Gaussian radius as in ProPresenter; canvas `shadowBlur = blur`), `color` |
| `styles.small` / `styles.big` | Text box `rect`, fonts (PostScript names), `size` pt, `tracking` (extra pt after every character, Cocoa `NSKern`; canvas `letterSpacing`), `lineHeight` (multiple of the font's natural line height), `align`, `valign` (`top`/`middle`/`bottom` inside `rect`), `maxLines` |

Fonts: `NeuzeitGro-Reg` and `NeuzeitGro-Bol`. Commercial, never committed (see `.gitignore`).

### Text layout (calibrated against ProPresenter 7 exports, matches to ±2 px)

ProPresenter lays text out with TextKit. To match it, both renderers use these rules
(metrics from the style's **regular** font at `size`: hhea ascender `A`, descender `D`, lineGap `G`;
Neuzeit: A = 0.7842 em, D = 0.2158 em, G = 0.1499 em):

* Wrap width = `rect.w − 10`; lines start at `rect.x + 5` (TextKit's 5 pt line padding).
* Tracking after a line's last character doesn't count toward the fit (CoreText behaves this way; the
  ProPresenter John 4:4-10 export depends on it).
* Line pitch `P = (A + D + G) × lineHeight`.
* Baseline of line *i* (0-based) = block top + `i × P + A`.
* Block height `H = (n − 1) × P + A + D + G + 5`.
* Block top: `valign` bottom → `rect.y + rect.h − H`; middle → `rect.y + (rect.h − H) / 2`; top → `rect.y`.
* Outline: drawn **under** the fill, stroke width `2 × size × strokePercent / 100`, so only the outer half shows.
* The Mac draws with font smoothing on (as ProPresenter does), which makes glyphs slightly heavier than a plain canvas fill.

## Slide

```json
{
  "id": "b3-2",
  "kind": "scripture",            // "scripture" | "point" | "quote"
  "style": "small",               // "small" | "big"  -> theme.styles[style]
  "runs": [
    { "t": "Ezekiel 36:33-36 (NLT)", "b": true },
    { "t": "\n35 … 'This former wasteland is now like the Garden of Eden! The abandoned and ruined cities now have strong walls and are filled with people!'" }
  ]
}
```

* `runs` is the whole slide text; `"b": true` = bold font, otherwise regular. `\n` is a hard line break.
  Everything else wraps at word boundaries inside `rect` width. **U+00A0 (no-break space) must not break**:
  the portal puts one between the last two words of each slide to prevent orphans.
* Plain text of a slide (cue screen, control GUI) = concatenation of all `t`.
* Renderers draw exactly these runs. They never re-split, re-case or re-punctuate.
* If a slide needs more than `maxLines` lines, the renderer still draws all of it (aligned per `valign`)
  and the portal flags it. The Mac never shrinks text.

## Service package (what a Mac downloads)

```json
{
  "id": "svc_01JC…",              // service id (campus + start time)
  "campusId": "central",
  "campusName": "Central",
  "label": "Central AM",
  "startsAt": "2026-11-15T09:30:00+13:00",
  "themeId": "central",           // campus default unless the push overrode it
  "messageId": "msg_…",
  "title": "Fresh Oil",
  "speaker": "Jane Doe",
  "version": 3,                   // increments on every Push Update
  "updatedAt": "2026-11-13T21:04:11Z",
  "slides": [ /* Slide[] */ ]
}
```

## Device API (Worker, token auth, not behind Cloudflare Access)

Header `Authorization: Bearer <device token>` (created in the portal under Admin → Machines; stored hashed).

| Request | Response |
|---|---|
| `GET /api/device/services` | `{ "device": {"id","name","campusId"}, "services": [ {id, campusId, campusName, label, startsAt, themeId, title, speaker, version, updatedAt} ] }`: services for the device's campus from 12 h ago onward, soonest first. |
| `GET /api/device/services/:id` | the full service package (any campus: a Mac may load another campus's notes) |
| `GET /api/device/services?campus=all` | same list across all campuses |
| `POST /api/device/operator/redeem` `{code}` | `{email, name, role}` for a one-time operator sign-in code (2 min, single use); 401 if expired/used, 403 if not an operator |
| `POST /api/device/operator/check` `{email}` | `{allowed, role, name}`: is this person still allowed to run the Macs? |
| `POST /api/device/heartbeat` `{appVersion, loadedServiceId, loadedVersion}` | `{ok:true}`: shows "last seen / what's loaded" in the portal |

Operator sign-in: the control GUI links to `GET /operator/signin?return=http://<mac>:<port>/control` (behind Access).
For Operator/Production/Admin users the portal redirects back with `#code=<one-time code>` in the fragment; the
return URL must be a `/control` page on a private IPv4 address, `localhost` or a `.local` name.

The Mac polls the list every 15 s, downloads changed packages, and caches them in
`~/Library/Application Support/LifeCG/Notes/<serviceId>.json`.

## Scripture input (what PAs paste)

```
John 4:4-10 (NLT)
4 He had to go through Samaria on the way. 5 Eventually he came to the Samaritan village …
```

Heading line = book, chapter[:verse range], translation. Accepted: `John 4:4-10 (NLT)`, `1 John 3:16 [NIV]`,
`Psalm 1 NIV`, `John 17:16-18 New Living Translation` (full names become the abbreviation); the slide always shows
`Book ch:v (ABBR)`. Verse text may be paraphrased; it is used as given. Poetry line breaks are reflowed. Verse
numbers may be glued to the text (`1Blessed`, `away.5 Therefore`, from PDFs); they count only in sequence (a jump
forward is allowed after a sentence end, for skipped verses).

## ProPresenter bundle (portal, legacy)

For campuses still building notes in ProPresenter 7, a push can email a `.probundle`: a zip of
`<name>.pro` (protobuf `rv.data.Presentation`) and the theme's image at
`Users/Shared/ProPresenter/Media/Assets/<uuid><file>` (the `.pro` refers to the same absolute path and to
`Media/Assets/<file>` under the show root, as ProPresenter's own exports do). Name:
`YYYY MM DD II CAMPUS SERVICE II Speaker - Title`. One slide per portal slide: the text box (theme rect, font,
size, tracking, line height, outline, shadow, vertical alignment; text as RTF with bold runs) above the theme's
layers (image or semi-transparent rectangle), plus an empty slide first and last (the operator takes the first
when the speaker walks on, so their first slide shows as "next"). Sent as `application/octet-stream`: labelled
as a zip, mail systems unpack or rewrap it. Only `.probundle`, never a bare `.pro` (that loses the background).

## Importing a document (portal)

PAs can import a PDF or Word (.docx) file instead of pasting. It's read in the browser (pdf.js / the .docx XML):
lines, paragraph gaps, superscript verse numbers and **highlight colours**. When the document is highlighted, the PA
picks which colours are slide text (cyan, used for examples, is off by default); lines of a scripture stay together,
other highlighted lines become separate items, and lines a PDF merely wrapped are joined. The same file can be kept
as the message's full **Notes**: stored in R2, attached to each push email next to the generated **Slides Preview**
PDF (or linked when both together would pass the 25 MiB email limit).

## Splitting rules (portal)

1. Scripture: heading in bold on every slide, then at most **3 lines** of body (small style width, real font metrics).
2. Prefer whole verses per slide; every slide's body starts with a verse number. Verse numbers stay inline, with
   U+00A0 after each so a number never ends a line on its own.
3. Split mid-verse only when a verse is longer than 3 lines on its own, or when the slide would otherwise hold a
   single line. Break at a comma or before "and" where possible. The slide keeps its punctuation and ends with a space and `…`
   (U+2026, one character; the space is U+00A0 so the `…` never wraps alone): `surprised, …`, `for Jews …`. The next
   slide body starts `<verse> … ` (e.g. `35 … This former wasteland`).
   Every slide starts with a capital letter (`2 but whose…` becomes `2 But whose…`). U+00A0 also follows each verse number.
4. Quotation marks open at a split are closed at the end of the slide and reopened at the start of the next.
5. No orphans: U+00A0 between the last two words of every slide body.
6. Point: text exactly as typed, all bold. One line at the big size → `big`, otherwise `small` (wraps).
7. Quote: quote text regular, author's name bold; split like scripture with `…`; the next slide starts `… `.
