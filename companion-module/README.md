# companion-module-lifenz-lowerthirds

A Bitfocus Companion module for **LowerThirds.app**, LIFE's macOS app that renders speaker-title lower thirds and sends them to ProPresenter 7 over Syphon. The app holds the state, and the module speaks the WebSocket protocol in [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md). Several Companion installs on different machines can connect to the same app at once. They share the on-air state and the Recent Titles list.

- Module id: `lifenz-lowerthirds`. Manufacturer: LIFE. Product: Lower Thirds. License: MIT.
- Repository: https://github.com/lifenzdotorg/lowerthirds
- The user-facing docs (actions, feedbacks, variables, presets) are in [`companion/HELP.md`](companion/HELP.md). Companion shows that file under the module's "?" button.

## Compatibility

| Companion       | Works? | Why |
| --------------- | ------ | --- |
| **4.3.x (incl. 4.3.4)** | yes | Accepts module API `1.0–1.14.x` and **`2.0.x`** |
| 5.0.x           | yes    | Accepts `1.0–1.14.x` and `2.0–2.1.x` |
| 5.1.x           | yes    | Accepts `1.0–1.15.x` and `2.0–2.2.x` |
| ≤ 4.2           | no     | API 2.0 needs Companion 4.3+ |

The module is built against **`@companion-module/base` 2.0.4**, the newest API that Companion 4.3.4 accepts. It uses the `node22` runtime, and Companion 4.3.4 bundles Node 22.22.2. Both 4.3.4 and 5.x accept the same `.tgz`.

Sources:

- `shared-lib/lib/ModuleApiVersionCheck.ts` in bitfocus/companion. At tag `v4.3.4` it has `MODULE_BASE_VERSIONS = ['1.14.0', '2.0.0']`, which becomes the semver range `~0.6 || 1 - 1.14.x || 2 - 2.0.x`. At `v5.0.0` it is `['1.14.0', '2.1.0']`, and at `v5.1.2` it is `['1.15.0', '2.2.0']`.
- `assets/nodejs-versions.json` at `v4.3.4` lists `node22: 22.22.2`. Base 2.0.x needs Node `^22.20`.
- https://companion.free/for-developers/module-development/api-changes/ maps API 2.0 to Companion 4.3+, 2.1 to 5.0+ and 2.2 to 5.1+.

> **Keep `@companion-module/base` pinned to `~2.0.x`** while any machine still runs Companion 4.3.x. Base 2.1.x or 2.2.x would build without errors, but Companion 4.3.4 would refuse to load the module.

## Install on Companion 4.3.4

### Option A: import the package (recommended)

1. Build it, or use a `.tgz` someone has already built:
   ```sh
   npm ci
   npm run package      # -> lifenz-lowerthirds-<version>.tgz
   ```
2. In Companion, open **Modules** and click **Import module package**. Choose the `.tgz`.
3. Open **Connections**, click **Add connection**, search for **LIFE Lower Thirds**, then set the Host and Port.

Repeat on every machine that runs Companion. To upgrade, import a newer `.tgz`; it shows up as a new version you can select.

### Option B: developer modules folder (for working on the module)

1. Make a folder, e.g. `~/companion-dev-modules/`, and clone or copy this directory inside it as `lifenz-lowerthirds/`.
2. In that copy run `npm ci && npm run build`. This creates `dist/main.js`, which `companion/manifest.json` points to.
3. In the Companion launcher window, open the cog (Advanced settings), set **Developer modules path** to `~/companion-dev-modules/`, and restart Companion.
4. Run `npm run dev` (tsc --watch). Companion reloads dev modules when files change.

## Configuration

| Field | Default     | Notes |
| ----- | ----------- | ----- |
| Host  | `127.0.0.1` | The Mac running LowerThirds.app. Use its LAN IP or hostname when Companion runs on another machine. |
| Port  | `9123`      | Must match the app's settings. |

Connection behaviour:

- The module connects to `ws://host:port/ws` and sends `{"type":"hello","client":"companion","name":"<connection label>","protocol":1}`.
- Status changes from **Connecting** to **OK** when the first `state` arrives. It shows **Connection failure** if the app can't be reached. It shows **Disconnected** if an open link drops; in that case the module retries automatically.
- Reconnect backoff is 1s, 2s, 4s and so on, up to 30s. It resets after a successful connect.
- Keepalive: the module sends a JSON `ping` every 10s. If nothing comes back (no `pong` or any other message) before the next ping, it drops the socket and reconnects.
- Renaming the connection re-sends `hello` with the new name.

## Development

You need Node **22.20 or newer**, because base 2.x requires it (`nvm use 22`). The project uses npm.

```sh
npm ci
npm run build          # tsc -> dist/
npm test               # tsc typecheck (incl. tests) + vitest
npm run package        # build + companion-module-build -> lifenz-lowerthirds-<version>.tgz
npm run mock-server    # fake LowerThirds.app on ws://0.0.0.0:9123/ws (+ /api/* HTTP)
```

Layout:

```
companion/manifest.json   module manifest (id, runtime node22, apiVersion filled in by the build)
companion/HELP.md         user help shown in Companion
src/main.ts               InstanceBase subclass (default export), wires everything together
src/client.ts             WebSocket client: hello, reconnect/backoff, keepalive, status
src/protocol.ts           protocol types + pure state -> variables/choices helpers
src/actions.ts            action definitions (rebuilt whenever the Recent list changes)
src/feedbacks.ts          On Air / Title is On Air
src/presets.ts            Control + Recent 1–10 presets
src/config.ts, upgrades.ts
test/mock-server.mjs      protocol-complete mock of LowerThirds.app
test/*.test.ts            vitest: protocol mapping + client/actions against the mock
```

Notes on API 2.x behaviour that shaped the code:

- **Variables in text fields.** API 2.0 removed `parseVariablesInString`. A `textinput` with `useVariables: true` is parsed by Companion before the callback runs, so the action receives text that already has the variables filled in. Users can also switch any field to expression mode.
- **Hiding fields.** Function-style `isVisible` is ignored in 2.x. The module uses `isVisibleExpression: "$(options:recent) == '__custom__'"`. In 2.x a field referenced from `isVisibleExpression` must have `disableAutoExpression: true`, and the Recent dropdown sets it.
- **Live dropdowns.** Dropdown choices are built from the latest `state.recent`. When the list changes (the module compares ids, titles and designations), it calls `setActionDefinitions` and `setFeedbackDefinitions` again.
- **Preset variables.** Preset text uses `$(lifenz-lowerthirds:recent_N_label)`. When a preset is placed on a button, Companion rewrites the prefix to the connection's real label (`replaceAllVariables` in `companion/lib/Instance/Definitions.ts`). The presets therefore work whatever the connection is called.

## Companion v5 notes

**Nothing needs to change to run on Companion 5.0 or 5.1.** Both accept API 2.0.x modules, so the same `.tgz` works.

Moving to a newer API makes sense only once every machine runs 5.x, and only if you want features from 2.1 (5.0+) or 2.2 (5.1+). Examples are action result values, layered presets, presets that use internal actions, and Node 26. When you do:

1. Bump `@companion-module/base` to `~2.1.x` (needs Companion ≥ 5.0) or `~2.2.x` (needs Companion ≥ 5.1). Bump `@companion-module/tools` to `^3.1`.
2. Optionally set `runtime.type` to `node26` in `companion/manifest.json`. Companion 5.1 bundles Node 26.12.1, and `node22` keeps working.
3. Run `npm run build` and fix any type errors. 2.2 changes include stricter variable-id validation, regex deprecations and typed value-feedback results. See https://companion.free/for-developers/module-development/api-changes/ and its v2.1 and v2.2 pages.
4. Raise `version` in `package.json` and re-package. **Companion 4.3.x will refuse to load this build.**

## License

MIT. See [LICENSE](LICENSE).
