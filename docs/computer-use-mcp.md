# Computer-use MCP for macOS

This local MCP server gives the Mistral Vibe CLI the computer-use tools of
pi-platform's `host` server, for a display or window you select:

| Tool | What it does |
| --- | --- |
| `screenshot` | Returns a JPEG (quality 70) of the display or window and its size in points. Pass `x`, `y`, `width` and `height` to capture just that region, enlarged 2× when its long side is 500 points or less, for reading small targets precisely. |
| `click` | Clicks a point with the left, right or middle button; `double` double-clicks. |
| `type_text` | Types text into whatever has keyboard focus. Newlines press Enter and tabs press Tab. |
| `press_keys` | Presses one key with optional modifiers, such as `enter`, `escape`, `cmd+s` or `cmd+shift+z`. |
| `scroll` | Turns the mouse wheel over a point. Positive notches scroll up, negative down. |
| `drag` | Holds a button along a straight path. `hold` keeps modifiers down and `steps` sets how many moves it makes. |

`screenshot` is read-only. The other tools send input, so Vibe asks before each call
under `--approval-policy ask`. A cropped screenshot's text gives the conversion from
its pixels back to points, such as `(1140 + px/2, 0 + py/2)`. Each tool rejects
arguments it doesn't take, and the error lists the ones it does.

Vibe keeps every screenshot in the conversation and sends all of them with each
later model request, so a long session gets slower as they pile up. Screenshots
are JPEGs at quality 70 to keep that cost down: about 300–400 KB for a full
display and 30–150 KB for a crop. pi-platform's `execute` tool is not included because
Vibe has its own shell tool.

## Build and connect

You need macOS 14 or later, the Xcode Command Line Tools, `uv`, and Vibe.
Run these commands from your checkout.

```sh
cd ~/Developer/mistral-vibe
mkdir -p .native-build
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  scripts/computer-use/Logic.swift scripts/computer-use/WindowControl.swift \
  -o "$PWD/.native-build/window-control"
uv run --no-project --script "$PWD/scripts/computer-use/server.py" --help
```

In **System Settings → Privacy & Security**, grant **Screen & System Audio Recording** and **Accessibility**
to the terminal or app that launches Vibe. Relaunch it after granting access.
macOS may list the native helper by name if it launched outside a terminal.

## Use the desktop or a whole display

From the repository root, register the server with your existing Vibe installation.
If you already registered a server called `computer-use`, remove that entry first
with `vibe mcp remove computer-use`.

```sh
vibe mcp add computer-use --transport stdio \
  --command "$(command -v uv)" \
  --arg=run --arg=--no-project --arg=--script \
  --arg="$PWD/scripts/computer-use/server.py" \
  --arg=--helper --arg="$PWD/.native-build/window-control" \
  --arg=--display --arg=main --tool-timeout-sec 25
vibe --approval-policy ask
```

Type `/mcp` in Vibe to check the connection. To select a different monitor, run
`.native-build/window-control displays` and replace `--arg=main` with
`--arg=<display ID>` when registering the server.

### When Vibe offers an old tool list

Vibe caches each MCP server's tool list for 24 hours from when it discovered the
tools, keyed by the server's command and arguments. Editing `server.py` changes
neither, so until the entry expires Vibe keeps offering the model the old tools and
descriptions while calls reach the new server. To check, run the server with the
same arguments you registered and `--check-cache`:

```sh
uv run --no-project --script scripts/computer-use/server.py \
  --helper "$PWD/.native-build/window-control" --display main --check-cache
```

It lists missing, removed and changed tools and when Vibe would stop using the
entry. To fix it, quit Vibe, rerun the command with `--clear`, and start a new
session. Pass `--name` if you registered the server under another name; the cache
is under `$VIBE_HOME`, `~/.vibe` by default.

To add a `/computer-use` shortcut and give Vibe more guidance for visual tasks,
install the accompanying skill from the repository root, then start a new session.

```sh
mkdir -p ~/.vibe/skills/computer-use
cp -n scripts/computer-use/skill/SKILL.md ~/.vibe/skills/computer-use/SKILL.md
```

You can ask normally or start with `/computer-use`, followed by your request.

Display mode sends screenshots of the whole selected display to Vibe and moves
the visible pointer. Coordinates are display points measured from its top-left.
The model can click, drag and scroll anywhere on the display. Keyboard input from
`type_text` and `press_keys` goes through the system like a real keyboard, to
whatever has focus: a text field, a popup, a dialog or system UI. Shortcuts such
as `cmd+tab` and `cmd+space` work. Approving a call in Vibe's terminal moves focus
there, so the helper first brings back the app that Vibe last clicked or dragged
in. Each result names the app that received the input.

### Test a desktop drag

Place a disposable file named `test.txt` on the actual desktop. Move the Terminal
window aside so the file and an empty area near the centre are visible. If icons
snap back into place, set the desktop's **Sort By** menu to **None**.

> Take a screenshot of my display. Find the `test.txt` icon on the macOS desktop,
> take a cropped screenshot around it to find its exact centre, and drag it to an
> empty spot near the centre of the display. Take another screenshot and confirm
> that the icon moved.

## Use one window

Open the target app in a normal, visible window.
List eligible windows. The first two columns are the window ID and process ID.

```sh
"$PWD/.native-build/window-control" windows
```

Replace the example IDs with the actual IDs from the list. If you're switching
from an existing registration, run `vibe mcp remove computer-use` first.

```sh
window_id=1234
process_id=5678
vibe mcp add computer-use --transport stdio \
  --command "$(command -v uv)" \
  --arg=run --arg=--no-project --arg=--script \
  --arg="$PWD/scripts/computer-use/server.py" \
  --arg=--helper --arg="$PWD/.native-build/window-control" \
  --arg=--window --arg="$window_id" --arg=--pid --arg="$process_id" \
  --tool-timeout-sec 25
vibe --approval-policy ask
```

In Vibe, use `/mcp` to check that the server is connected. Update the registration
with the new IDs if you reopen the target window. Run `vibe mcp remove computer-use`
when you finish.

### Test a window

Open [the demo](../scripts/computer-use/demo.html) in a browser window and
select that window when configuring the server. Keep the browser and Vibe
side by side so Vibe does not cover the points the tools will click or drag.
Ask Vibe to take a screenshot, click the message field, type “Hello from Vibe”,
press Enter, press `cmd+k`, drag **Drag me** to **Drop here** while holding Shift,
double-click and then right-click **Double- or right-click me**, scroll the list
down to line 30, and take another screenshot. The demo should show “Submitted:
Hello from Vibe”, “Pressed: cmd+k”, “Drag complete. Shift was held.”, “Right-click
received.” and “Scrolled to line 30.” Out-of-bounds coordinates, such as an `x`
larger than the reported width, are rejected without sending input.

To test keys in a popup, ask Vibe to click **Ask for my location** and then press
`escape`. The browser's location prompt should close.

Before typing or pressing keys, the helper brings the selected window forward.
Input then goes to whatever has focus, popups included. Coordinates start at the top-left of the window, including its title bar.
Take a fresh screenshot if the layout changes. Keep the target still and
visible during a drag. The helper checks the path and releases the mouse button
if the window moves or the path becomes obstructed.

## Approve from Telegram

To start computer-use sessions from Telegram and approve each action there, see
[remote-telegram.md](remote-telegram.md).

## Security and limitations

The tools can operate anything on the screen, including the terminal running
Vibe and its approval prompts. A model that clicks or types there can answer
its own approval requests or type into its own prompt. Keep approvals in front
of you, watch what the model does, and select a single window instead of a
display when the task allows it.

- **Approval is the main safeguard.** Under `--approval-policy ask`, Vibe asks
  before every click, drag, scroll and key. Setting a tool's `permission` to
  `"always"` in `~/.vibe/config.toml` removes that check.
- **Display mode allows input anywhere on the display.** Clicks, scrolls and both
  ends of a drag must be on the selected display, and a drag's whole path must
  stay on it. Nothing else is checked.
- **Window mode keeps the pointer on one window.** Every point of a click,
  scroll or drag, including the whole drag path, must be over the selected window
  and not covered by another; the helper releases the button if the window
  moves. Keyboard input goes to whatever has focus once the window is in front,
  so a shortcut such as `cmd+tab` can still reach other apps.
- **Keys go wherever focus is.** If focus moves between the call and the key
  press, the input lands in the newly focused app. The result names that app.
- **Screenshots show everything on the selected display or window,** including
  notifications, other apps and Vibe's own transcript. They are sent to the model
  provider. Choose a display or window whose contents you are comfortable sharing.
- **Text on screen can try to instruct the model.** A web page or document can
  contain instructions; treat what the model does after reading one with care.
