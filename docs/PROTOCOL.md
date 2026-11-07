# LifeCG control protocol (v1)

The macOS app (**LifeCG.app**) is the single source of truth. Any number of
Companion instances (or other clients) connect to it; every state change is
broadcast to all of them, so the Recent Titles list is shared across instances.

Default port: **9123** (configurable in the app). Bind: all interfaces.

## WebSocket — `ws://<host>:9123/ws`

All messages are UTF-8 JSON text frames with a `type` field.

### Client → app

| type | fields | effect |
|---|---|---|
| `hello` | `client` (string, e.g. `"companion"`), `name` (instance label), `protocol` (number, `1`) | Identify. App replies with `state`. |
| `show` | `title` (string, required, non-empty after trim), `designation` (string, optional) | Put this title on air. If something is already on air, it animates out and the new one animates in. Adds/bumps the entry in Recent. |
| `showRecent` | `id` (string) **or** `index` (number, 0 = most recent) | Show an entry from the Recent list. |
| `hide` | — | Animate the title off air. |
| `toggle` | — | If on air → hide. If off air → re-show the last shown title (if any). |
| `removeRecent` | `id` | Remove one entry from Recent. |
| `clearRecent` | — | Empty Recent. |
| `ping` | — | App replies `{"type":"pong"}`. |

Unknown types → `{"type":"error","message":"..."}`. Invalid `show` (empty title) → `error`.

### App → client

`state` (sent on connect, after `hello`, and broadcast after every change):

```json
{
  "type": "state",
  "protocol": 1,
  "onAir": true,
  "current": { "id": "a1b2c3d4", "title": "Ps Luke de Jong", "designation": "Lead Pastor" },
  "last":    { "id": "a1b2c3d4", "title": "Ps Luke de Jong", "designation": "Lead Pastor" },
  "recent": [
    { "id": "a1b2c3d4", "title": "Ps Luke de Jong", "designation": "Lead Pastor", "lastUsed": "2026-11-08T09:30:00Z" }
  ]
}
```

- `current` is `null` when off air. `last` is the most recently shown title (used by `toggle`), or `null`.
- `designation` is always a string (`""` when absent). The graphic only draws the designation bar when it is non-empty.
- `recent` holds at most **20** entries, most recently used first.
- `id` is stable for a given title+designation: first 8 hex chars of SHA-256 of
  `lowercase(trim(title)) + "\n" + lowercase(trim(designation))`. Showing the same
  title again moves it to the top rather than duplicating it.

## HTTP (handy for testing, Stream Deck "web request", curl, etc.)

| method & path | body | result |
|---|---|---|
| `GET /api/state` | — | the `state` object above |
| `POST /api/show` | `{"title":"…","designation":"…"}` | 200 + state |
| `POST /api/hide` | — | 200 + state |
| `POST /api/toggle` | — | 200 + state |
| `POST /api/recent/clear` | — | 200 + state |

### Legacy NodeCG compatibility

The old Companion module (`lifenz-nodecg`) POSTed to
`<prefix>sistas21/remote/speakertitle`. The app accepts that too:

- `POST /sistas21/remote/speakertitle` `{"action":"go","name":"…","designation":"…"}` → show
- `POST /sistas21/remote/speakertitle` `{"action":"no"}` → hide

So an old Companion config can be pointed at `http://<cg-mac>:9123/` while migrating.
