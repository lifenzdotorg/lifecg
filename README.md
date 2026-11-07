# LowerThirds

Speaker-title lower thirds for **ProPresenter 7**, driven from **Bitfocus Companion**.
It replaces the old NodeCG setup (`lifenz-nodecg` Companion module → NodeCG `sistas21` bundle).

```
 Companion (any number of        ws://cg-mac:9123/ws        LowerThirds.app (CG Mac Studio)        Syphon         ProPresenter 7
 instances, any machine)   ───────────────────────────▶   state + recent titles + renderer  ─────────────▶  Live Video input
  [Show Title] [Hide] ...   ◀── state broadcast to all ──   1920×1080 BGRA, premultiplied alpha   "LowerThirds"   (with alpha)
```

| Folder | What |
|---|---|
| [`app/`](app) | Native macOS app (Swift, AppKit/SwiftUI, Metal). Renders the graphic and publishes it as a Syphon server. Hosts the control server. |
| [`companion-module/`](companion-module) | Companion module `lifenz-lowerthirds` (Companion **4.3.x and 5.x**). |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | The WebSocket/HTTP protocol between them. |

## The graphic

Matches the original LIFE design: white name bar, optional dark designation bar (drawn only when a designation is set), and the plus ornaments. Both bars size to the text and are right-anchored. The background gradient and plus layers are the original artwork (`app/Sources/LowerThirdsCore/Resources`).
Animation: the gradient fades in, the bars wipe in from the right, then the text fades in. Changing title while on air plays out → in.

![reference](docs/reference-composite.png)

**Font:** the design uses **Neuzeit Grotesk** (Bold for the name, Regular for the designation). It is a commercial font and is **not** in this repo. Install `NeuzeitGro-Bol` / `NeuzeitGro-Reg` on the CG Mac. Without it the app falls back to Avenir Next at the same size and shows the fallback in orange under *Settings*.

## Using it

1. Run **LowerThirds.app** on the CG Mac. It lives in the menu bar (closing the window keeps it running). Turn on *Settings → Launch at login*.
2. In ProPresenter 7, add a **Live Video** input → **Syphon** → `LowerThirds`, and put it on a layer above your slides/video so alpha keys through.
3. In each Companion, import `lifenz-lowerthirds-x.y.z.tgz` (Modules → Import module package), add a connection, and set **Host** = the CG Mac's IP (the app's *Connections* tab lists it) and **Port** = `9123`.
4. Buttons: **Show Title** (type a Title + optional Designation, *or* pick from the **Recent Titles** dropdown of the last 20), **Hide**, **Toggle**, **Show Recent #N**. There are presets for all of these.

The Recent list lives in the app, so every Companion instance shares it. It is saved in `~/Library/Application Support/LowerThirds/recent.json`.

**Migrating from NodeCG:** the app also accepts the old module's requests (`POST /sistas21/remote/speakertitle`). An old Companion connection keeps working if its *NodeCG Instance* prefix is changed to `http://<cg-mac>:9123/`.

## Building

### App: needs only the Xcode Command Line Tools

```bash
app/scripts/build-app.sh
```

This produces `app/build/LowerThirds.app` (universal, ad-hoc signed), plus two dev tools:

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
cd companion-module && npm ci && npm test && npm run package   # → lifenz-lowerthirds-<version>.tgz
```

See [`companion-module/README.md`](companion-module/README.md) for the version notes for 4.3.4 and v5.
