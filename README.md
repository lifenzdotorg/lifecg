# LifeCG

Speaker-title lower thirds for **ProPresenter 7**, driven from **Bitfocus Companion**.
It replaces the old NodeCG setup (`lifenz-nodecg` Companion module → NodeCG `sistas21` bundle).

```
 Companion (any number of        ws://cg-mac:9123/ws        LifeCG.app (CG Mac Studio)        Syphon         ProPresenter 7
 instances, any machine)   ───────────────────────────▶   state + recent titles + renderer  ─────────────▶  Live Video input
  [Show Title] [Hide] ...   ◀── state broadcast to all ──   1920×1080 BGRA, premultiplied alpha   "LifeCG"   (with alpha)
```

| Folder | What |
|---|---|
| [`app/`](app) | Native macOS app (Swift, AppKit/SwiftUI, Metal). Renders the graphic and publishes it as a Syphon server. Hosts the control server. |
| [`companion-module/`](companion-module) | Companion module `lifenz-lifecg` (Companion **4.3.x and 5.x**). |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | The WebSocket/HTTP protocol between them. |

## The graphic

Matches the original LIFE design: white name bar, optional dark designation bar (drawn only when a designation is set), and the plus ornaments. Both bars size to the text and are right-anchored. The background gradient and plus layers are the original artwork (`app/Sources/LifeCGCore/Resources`).
Animation is set separately for **on** and **off** in the app's *Settings* (any combination):

| Option | Look |
|---|---|
| Slide box, fade text | Bars wipe in from the right, then the text fades in (the original NodeCG look, and the default) |
| Slide box and text | Bars slide out from behind the plus ornaments with their text already on them |
| Fade | The whole graphic fades |
| Cut | Instant |

Changing title while on air plays the off transition, then the on transition. Off transitions run a little faster than on.

**Output:** 1920×1080 at **50 fps** by default (LIFE's 1080p50 standard; 25/29.97/30/59.94/60 are in *Settings*).
Frames are composited on the GPU on a fixed clock, one animation step per frame, and published every frame. The app
window shows the measured rate next to the setting. In ProPresenter set the input's **Alpha Type** to **Premultiplied**.

![reference](docs/reference-composite.png)

### Themes (other campuses)

Every look is a **theme**: a folder with `theme.json` (bar positions, colours, fonts, padding, shadow, anchor side)
plus optional full-frame `background.png` / `foreground.png` layers for anything that doesn't move with the text.
The built-in **LIFE** theme lives in [`app/Themes/life`](app/Themes/life). Imported themes are saved to
`~/Library/Application Support/LifeCG/Themes/<id>/` and can be edited by hand (then press *Reload*).

**Make a theme from a sample PNG:** in the app's *Themes* tab, drop in (or *Import from PNG…*) a 1920×1080 PNG of a
finished speaker title, ideally with a transparent background. The app finds the bars, their colours and alpha,
padding, text colour and size, baseline, anchor side and shadow. It separates the fixed artwork into background and
foreground layers, then shows the sample and a re-drawn version side by side with a match score. Type the sample's
exact name/designation text and pick its fonts for a precise size and letter-spacing match (fonts can't be read
from pixels). Switch themes in the app or from Companion (*Set Theme*). The change applies immediately.

**Font:** the design uses **Neuzeit Grotesk** (Bold for the name, Regular for the designation). It is a commercial font and is **not** in this repo. Install `NeuzeitGro-Bol` / `NeuzeitGro-Reg` on the CG Mac. Without it the app falls back to Avenir Next at the same size and shows the fallback in orange under *Settings*.

## Using it

1. Run **LifeCG.app** on the CG Mac. It lives in the menu bar (closing the window keeps it running). Turn on *Settings → Launch at login*.
2. In ProPresenter 7, add a **Live Video** input → **Syphon** → `LifeCG`, and put it on a layer above your slides/video so alpha keys through.
3. In each Companion, import `lifenz-lifecg-x.y.z.tgz` (Modules → Import module package), add a connection, and set **Host** = the CG Mac's IP (the app's *Connections* tab lists it) and **Port** = `9123`.
4. Buttons: **Show Title** (type a Title + optional Designation, *or* pick from the **Recent Titles** dropdown of the last 20, with an optional **Auto clear** tickbox; the time is set in the app's *Settings*, default 8 s), **Hide**, **Toggle**, **Show Recent #N**. There are presets for all of these. The auto-clear timer runs in the app, so it still fires if Companion drops off.

The Recent list lives in the app, so every Companion instance shares it. It is saved in `~/Library/Application Support/LifeCG/recent.json`.

**Migrating from NodeCG:** the app also accepts the old module's requests (`POST /sistas21/remote/speakertitle`). An old Companion connection keeps working if its *NodeCG Instance* prefix is changed to `http://<cg-mac>:9123/`.

## Building

### App: needs only the Xcode Command Line Tools

```bash
app/scripts/build-app.sh
```

This produces `app/build/LifeCG.app` (universal, ad-hoc signed), plus two dev tools:

- `app/build/lt-render`: `--selftest`, `--serve <port>` (headless server), or `<out.png> "<title>" "<designation>"` to render a still.
- `app/build/syphon-grab <server> <out.png>`: captures a frame from any Syphon server, to check the real output.

Syphon is vendored in [`app/Vendor/Syphon`](app/Vendor/Syphon). It is patched so its Metal shaders compile at runtime, because the Command Line Tools have no `metal` compiler. See that README.

`app/Package.swift` also exists for opening the project in Xcode. On this Mac SwiftPM is broken by stale Command Line Tools files; see `app/Vendor/Syphon/README.md` for the fix. The shell build does not need SwiftPM.

### Signing and notarisation

```bash
SIGN_ID="Developer ID Application: <Org> (<TEAMID>)" VERSION=1.0.0 app/scripts/notarize.sh
```

This signs with the hardened runtime, notarises with `notarytool`, staples the ticket, and zips the result. See the script header for the one-time `store-credentials` step. The app is deliberately **not** sandboxed: Syphon's global server lookups don't work in the App Sandbox.

### Companion module

Needs **Node 22** (the module API 2.0 runtime).

```bash
cd companion-module && npm ci && npm test && npm run package   # → lifenz-lifecg-<version>.tgz
```

See [`companion-module/README.md`](companion-module/README.md) for the version notes for 4.3.4 and v5.
