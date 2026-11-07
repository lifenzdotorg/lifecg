## LIFE Lower Thirds

Controls **LowerThirds.app**, the macOS app that renders speaker-title lower thirds and sends them to ProPresenter 7 over Syphon. The app holds the state, including the shared Recent Titles list. Any number of Companion installs can connect to it at once, and all of them see the same titles and on-air state.

### Configuration

| Field | Default   | Notes                                                                     |
| ----- | --------- | ------------------------------------------------------------------------- |
| Host  | 127.0.0.1 | IP or hostname of the Mac running LowerThirds.app                         |
| Port  | 9123      | As set in the app's settings                                              |

The module connects to `ws://host:port/ws` and reconnects automatically if the connection drops. The connection shows **Connecting**, **OK**, **Connection failure** (cannot reach the app) or **Disconnected** (the link dropped and the module is reconnecting).

### Actions

- **Show Title**: pick an entry from **Recent Titles**, or choose _"— Type a new title —"_ and enter a **Title** and an optional **Designation**. Both text fields accept variables, e.g. `$(internal:custom_speaker)`. The Recent list in the dropdown updates live.
- **Show Recent Title by position**: 1 is the most recent title. Nothing happens if that position is empty.
- **Hide Title**
- **Toggle Title**: hides the title if it's on air, otherwise shows the last title again.
- **Clear Recent Titles**: empties the shared list on every connected Companion.
- **Remove Recent Title**

If a button refers to a recent title that has since been removed from the list, pressing it does nothing and logs a warning.

### Feedbacks

- **On Air**: any title is on air.
- **Title is On Air**: a specific recent title is on air, or a title matching the text you enter (case-insensitive; leave the designation blank to match any designation).

### Variables

| Variable                                                     | Meaning                                                 |
| ------------------------------------------------------------ | ------------------------------------------------------- |
| `on_air`                                                     | `true` / `false`                                        |
| `title`, `designation`                                       | The title on air now (empty when nothing is on air)     |
| `last_title`, `last_designation`                             | The last title shown (used by Toggle)                   |
| `recent_count`                                               | Number of recent titles (0–20)                          |
| `recent_N_title`, `recent_N_designation`, `recent_N_label`   | N = 1…20. The label is the title and designation on two lines, for button text |

### Presets

- **Control**: Toggle (turns red while on air), Hide, and a button showing the current title.
- **Recent Titles**: Recent 1–10. Each button shows that position's title and designation and puts it on air when pressed.
