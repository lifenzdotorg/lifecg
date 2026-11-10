# LifeCG notes portal (cloud)

The cloud half of the notes platform (see `docs/notes-platform/PLAN.md` and the contract in
`docs/notes-platform/FORMAT.md`): a Cloudflare Worker with D1, R2 and static assets.

* **Portal** (behind Cloudflare Access): paste notes → blocks → auto-split slides with live 1920×1080
  previews in the real fonts → edit → push to campus + service time → PDF emailed.
* **Device API** (`/api/device/*`, bearer token, not behind Access): what the Mac app polls.

```
cloud/
  wrangler.jsonc          Worker config: D1 (DB), R2 (PRIVATE), assets, send_email (EMAIL)
  migrations/             D1 schema + campus seed
  shared/                 code used by the portal AND the tests (no DOM, no Worker APIs)
    parse.ts              pasted text → blocks, scripture reference/verse parsing, quotes
    split.ts              FORMAT.md splitting rules (injected measure function)
    layout.ts             word wrap + text box layout (tracking, lineHeight, valign)
    quotes.ts             open-quote tracking across slide splits
    edit.ts               split-at-cursor / merge for the reflow view
    warnings.ts           per-slide checks (lines, US spellings, verse number / capital)
    markup.ts             runs ⇄ `**bold**` textarea markup, no-orphan NBSP
    themes.ts             imports ../notes-themes/*/theme.json
  src/worker/             Hono app: auth (Access JWT), API, device API, email, R2
  src/portal/             Preact UI, canvas renderer, font loading, pdf-lib PDF
  scripts/build-portal.mjs  esbuild → public/ (+ copies ../notes-themes to public/themes)
  test/                   vitest (fixed-width measure + real Neuzeit metrics via opentype.js)
```

## Run locally

Needs Node 20. Everything is local (miniflare); nothing touches your Cloudflare account.

```sh
cd cloud
npm i
cp .dev.vars.example .dev.vars            # DEV_USER_EMAIL, ADMIN_EMAILS, EMAIL_DRY_RUN=1
npx wrangler d1 migrations apply notes --local
# fonts (copy NeuzeitGro-Reg.ttf / NeuzeitGro-Bol.ttf into cloud/.fonts first; never commit them):
for f in NeuzeitGro-Reg NeuzeitGro-Bol; do npx wrangler r2 object put notes-private/fonts/$f.ttf --file .fonts/$f.ttf --content-type font/ttf --local; done
npm run dev                               # builds the portal, then wrangler dev on http://localhost:8788
```

(`npm run fonts:local` runs the same font upload; `npm run watch` rebuilds the portal on change.)

Port 8788 because 8787 is often taken; the Mac app's dev setting should point at `http://localhost:8788`.
Local data (D1, R2) lives in `cloud/.wrangler/state` and survives restarts.

```sh
npm test            # vitest: parser, splitter, layout, edit, time, Access JWT; real-font tests skip without .fonts/
npm run typecheck   # portal + worker
```

### Trying the device API locally

Create a machine in the portal (Admin → Machines; the token is shown once), push a message, then:

```sh
curl -H "Authorization: Bearer $TOKEN" http://localhost:8788/api/device/services
curl -H "Authorization: Bearer $TOKEN" http://localhost:8788/api/device/services/<serviceId>
curl -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"appVersion":"1.0","loadedServiceId":"<serviceId>","loadedVersion":1}' http://localhost:8788/api/device/heartbeat
```

## Environment

| Name | Where | Meaning |
|---|---|---|
| `DB` | D1 binding | database `notes` |
| `PRIVATE` | R2 binding | private bucket `notes-private`: `fonts/<name>.ttf`, `pdfs/<serviceId>/v<n>.pdf` |
| `EMAIL` | `send_email` binding | Cloudflare Email Service |
| `ASSETS` | assets binding | built portal in `public/` |
| `EMAIL_FROM`, `EMAIL_FROM_NAME` | var | default `notes@prodapps.life`, `LIFE Speaker Notes` |
| `ADMIN_EMAILS` | var / secret | comma-separated; always admin. Set the first admin here |
| `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD` | var | e.g. `lifenz.cloudflareaccess.com` and the Access app's AUD tag. When set, every portal request must carry a valid `Cf-Access-Jwt-Assertion` (RS256, checked against the team certs, aud/iss/exp). **Set both in production.** |
| `DEV_USER_EMAIL` | `.dev.vars` only | local dev: act as this user (used only when ACCESS_* are unset) |
| `EMAIL_DRY_RUN` | `.dev.vars` | `1` = log the email instead of sending. With it off, `wrangler dev` uses the local email simulator (writes the message to temp files, sends nothing) |

Roles: `pa` (own messages), `production` (all messages, push anywhere), `admin` (+ campuses, recipients,
users, machines). Any Access-authenticated `@lifenz.org` address is created as `pa` on first visit; other
domains need an admin to add them under Admin → Users.

## Production (deployed 10 Nov 2026)

* Worker `lifecg-notes` on **https://notes.prodapps.life** (custom domain; workers.dev and preview URLs off).
* D1 `notes` (id in `wrangler.jsonc`), R2 `notes-private` (no public access) holding `fonts/` and `pdfs/`.
* Email Sending enabled on `prodapps.life`; sender `notes@prodapps.life`.
* Cloudflare Access (team `lifeprodapps`): self-hosted app "LIFE Speaker Notes portal" on `notes.prodapps.life`,
  policy *allow emails ending in @lifenz.org*, one-time PIN login, 7-day sessions. The Worker verifies the
  Access JWT (`ACCESS_TEAM_DOMAIN` var + `ACCESS_AUD` secret) and **fails closed** if `ACCESS_AUD` is missing.
* Secrets (never in this repo): `ACCESS_AUD`, `ADMIN_EMAILS`.
* **Macs** reach `/api/device/*` through Access with a **service token** (Access → Service credentials) added to
  the app as a *Service Auth* policy, plus their per-machine bearer token. There is no bypass rule.
  Enter both in LifeCG → Notes → Portal sync.

* **Themes** (`notes-themes/`, from the ProPresenter files on the graphics share): `central` (Central), `ns`
  (North, South), `east` (East, Tauranga; `east-bg` is the "with background" version), `chapel`, `west`.
* **Import / Notes**: "Import PDF or Word…" in the editor (`shared/docimport.ts`, `src/portal/importDoc.ts`; pdf.js
  is served from `/vendor` and loaded only when used). The message's full **Notes** file lives in R2 under
  `notes/<messageId>/`; each push records which file it was sent with.
* **ProPresenter .probundle** (legacy setups during the changeover): Admin → Campuses → "Email a ProPresenter
  .probundle with each push"; the push dialog ticks it per campus. Built in the browser (`shared/probundle.ts`,
  loaded on demand as `public/probundle.js`) from the campus theme, with the background image inside the bundle;
  uploaded to R2 and attached to the push email (before the Notes when both won't fit). Schema: `shared/propresenter/`.
* **Roles**: PA (own messages), **Operator** (a PA who can also run the CG Macs' control GUI by signing in with
  their LIFE login: `/operator/signin`), Production (all messages, push anywhere), Admin (also campuses, users,
  machines). `ADMIN_EMAILS` are always admin.

Redeploy (Node ≥ 22): `npm run build && npx wrangler deploy`; schema changes: `npx wrangler d1 migrations apply notes --remote`.

## Notes

* Layout follows FORMAT.md "Text layout" (TextKit 5 pt padding: wrap width `rect.w − 10`). The splitter wraps
  in the **narrowest** small/big box across themes (Central 1692.8 − 10), so a slide that fits once fits everywhere.
  The tracking after a line's last character is not counted when testing the fit (reproduces ProPresenter's wraps). Previews and warnings use the selected preview theme.
* Line wrapping uses the real fonts: the portal loads them with `FontFace` from `/fonts/<name>.ttf`
  (signed-in users only) and measures with canvas; tests measure with opentype.js. Both match the line
  breaks in LIFE's ProPresenter export of John 4:4-10.
* The PDF is built in the browser with pdf-lib (bundled) using Helvetica for the text (accents outside
  WinAnsi are stripped in the PDF only; the slides themselves are images rendered in Neuzeit).
* A localhost-only `window.__notes` hook exposes the renderer for visual checks against ProPresenter exports.
