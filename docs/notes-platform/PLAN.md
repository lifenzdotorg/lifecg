# LifeCG Notes Platform: plan

Status: **draft for review** (branch `notes-platform`). `main` keeps shipping the speaker-title LifeCG unchanged;
this branch merges `main` in regularly.

## What it replaces

Today a PA cleans up the speaker's Word notes, imports them into ProPresenter, reflows them by hand to the
LIFE rules, exports a Pro bundle and emails it plus the notes to graphics@lifenz.org, the campus production
manager and the speaker (Central also cc Matt Linton and Dan Cotton). Operators run the slides from
ProPresenter, and tweaks mean a trip to the booth.

## Shape

```
 PA / production manager                Cloudflare (prodapps.life)                     Campus CG Mac (LifeCG.app)
 ───────────────────────                ──────────────────────────                     ──────────────────────────
 Portal (browser)  ──── HTTPS ────▶  Worker + D1 database + R2 files  ◀── polls ──  Notes sync (local cache, works offline)
   paste, reflow, preview            Cloudflare Access login                        Renderer: main Syphon  "LifeCG"
   pick campus + service              PDF + email via notes@prodapps.life                     cue Syphon   "LifeCG Cue" (25 fps)
   Push Update                                                                       LAN control GUI  http://<mac>:9123/  (PIN)
                                                                                     Companion: titles, Clear, Clear All
```

* **Cloud never controls output.** The Mac only *downloads*. Taking slides live happens only on the LAN.
* **The Mac keeps working offline.** It caches every upcoming service, so an internet drop mid-service does nothing.

## Content model and the LIFE rules

A **message** (speaker, title, date written) holds an ordered list of **blocks** that the PA pastes or types:

| Block | Detected when | Rendered as |
|---|---|---|
| **Scripture** | first line looks like `John 4:4-10 (NLT)` | Reference + translation in **bold** on top of *every* slide, then at most **3 lines** of text (lower third max 4 lines). Theme style "Small". |
| **Point** | anything else | Exactly as typed (case, line breaks), always **bold**. If it fits one line at the big size → "Big" style; else "Small" style, wrapped. |
| **Quote** | starts with a quote mark | Quote text regular, author's name the only bold part. Small style. |

Automatic slide splitting for scripture and quotes (the PA can override every break):

* Split at verse boundaries where possible; each slide starts with a verse number.
* When a verse has to break: end the slide with `...`, start the next with `<verse> ... ` (e.g. `35 ... 'This former…`).
* No orphan (single word) on the last line; prefer breaking after a comma / before "and".
* Open quotation marks are closed at the end of the slide and reopened on the next.
* Checks shown as warnings (not auto-changed): American spellings (honor → honour…), square brackets around
  the translation, slide not starting with a verse number or capital letter.

Line counting uses the real font metrics (Neuzeit Grotesk, loaded privately) in the portal; the Mac renders the
same slide text with CoreText, so what the PA sees is what goes to air.

## Themes (from the existing ProPresenter themes)

Read straight out of the `.proTheme` files on the graphics share, so geometry matches today's look exactly:

| Theme | Small (scripture/quote/long point) | Big (short point) | Background |
|---|---|---|---|
| **Central** (LIFE Speaker Notes 2022 V6; also N + S) | box 113.6, 753.1, 1692.8 × 290.2, bottom-aligned · Neuzeit 54 · tracking 2.0 · line height 0.9 | box 113.6, 953.6, 1692.8 × 97.5 · Neuzeit Bold 75 | `2022_SPEAKERNOTES_BG_WIP_03.png` gradient + plus marks |
| **West** (West Themes 2025) | box 87.3, 181.1, 1745.5 × 290.2, centred | box 113.6, 277.5, 1692.8 × 97.5 · Bold 75 | black bar 0, 181.1, 1920 × 290.2 at 50% |

All text: white, 2 px stroke at 30% black, shadow 270° / 10 px / blur 20 / 50%.
Chapel, Tauranga, East and others come from their `.protheme` files the same way. In the prototype themes are
built into the app; managing them from the portal comes in phase 2.

## Mac app additions

* **Notes sync**: the Mac is registered once in the portal (gets a token and default campus). It polls every
  ~15 s for that campus's upcoming services and caches them to disk.
* **Main output**: notes and titles share the existing "LifeCG" Syphon output; one replaces the other.
* **Cue output**: new Syphon server "LifeCG Cue", 1920×1080 at 25 fps, plain text: *current* on top,
  *next* below. No speaker titles.
* **LAN control GUI** (served by the app on port 9123, iPad first, desktop and phone too):
  * 4-digit PIN set in the Mac's Settings, or **Sign in with LIFE account** for portal users with the
    Operator role (or Production/Admin), with an optional *Remember me on this device* (30 days). PIN sign-ins
    are never remembered.
  * Service picker (upcoming services for this campus; theme defaults to the campus's, switchable).
  * Slide list, plain text by default, toggle to show rendered lower-third crops.
  * Tap = **live**. **Preview** = put the slide in the cue screen's *next* only. **Clear** = take current off.
    **Clear All** = also blank *next* on the cue screen.
  * Banner when the portal pushes an update: "Updated notes available. Load now?" Loading keeps your place.
* **Companion**: existing *Hide/Clear title* also clears the current slide; new action *Clear All*.

## Portal

* Login with Cloudflare Access (one-time code to a @lifenz.org email). Roles: **PA** (own messages),
  **Production** (all messages, all campuses, can push anywhere), **Admin** (campuses, email lists, machines, users).
* **Messages**: paste notes → blocks → reflow view with live rendered previews in the chosen campus theme;
  edit text, split/merge slides, change block type.
* **Push** a message to one or more *campus + service date/time* (e.g. Central AM this week, North next week).
  Pushing again after edits sends an update to that Mac.
* On push, a **PDF** (each slide rendered, plus the plain text) is generated and emailed from
  `notes@prodapps.life` to the campus list + speaker + the PA. Re-push sends an "updated" email.
  Each campus's list (production manager, exec, graphics@lifenz.org as a backup, …) is edited in the portal.
* Every output is 1920×1080; the portal doesn't offer other sizes, which removes the "wrong canvas" mistake.
* **History**: every message stays searchable; re-push an old one to a new campus/date in two clicks.

## Phasing

**Prototype (this week)**
1. Mac: notes model + renderer for Central and West, cue Syphon output, LAN control GUI with PIN, Companion clear
   changes. Loads notes from a local JSON file and from the cloud.
2. Cloud: Worker + D1 + Access, paste → auto-split → reflow editor with previews, push to campus/service,
   Mac sync endpoint, PDF and email.

**Phase 2**: themes edited/uploaded in the portal and synced to Macs, remaining campus themes, spelling and
style checks, user/role admin screens, audit history, polish.

## Not committed to git

The repo is public. The Neuzeit fonts stay out of it (private R2 bucket for the portal, installed on Macs);
no secrets or email lists in code.
