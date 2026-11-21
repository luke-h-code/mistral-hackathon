# Computer-use MCP for macOS

This local MCP server gives the Mistral Vibe CLI the computer-use tools of
pi-platform's `host` server, for a display or window you select:

| Tool | What it does |
| --- | --- |
| `screenshot` | Returns a JPEG (quality 70) of the display or window and its size in points. Pass `x`, `y`, `width` and `height` to capture just that region, enlarged 2× when its long side is 500 points or less, for reading small targets precisely. |
| `click` | Clicks a point with the left, right or middle button; `double` double-clicks. |
| `type_text` | Types text into the focused control. Newlines press Enter and tabs press Tab. |
| `press_keys` | Presses one key with optional modifiers, such as `enter`, `cmd+s` or `cmd+shift+z`. |
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
  scripts/computer-use/WindowControl.swift \
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

Vibe caches each MCP server's tool list under `~/.vibe/logs/mcp-descriptors/unified/`,
keyed by the server's command and arguments. After you change the tools in
`server.py`, quit Vibe, delete that folder's JSON files, and start a new session,
or Vibe keeps offering the model the old tool list.

To add a `/computer-use` shortcut and give Vibe more guidance for visual tasks,
install the accompanying skill from the repository root, then start a new session.

```sh
mkdir -p ~/.vibe/skills/computer-use
cp -n scripts/computer-use/skill/SKILL.md ~/.vibe/skills/computer-use/SKILL.md
```

You can ask normally or start with `/computer-use`, followed by your request.

Display mode sends screenshots of the whole selected display to Vibe and moves
the visible pointer. Coordinates are display points measured from its top-left.
Keyboard input from `type_text` and `press_keys` goes to the app that Vibe last
clicked or dragged in. After you approve the call in Vibe's terminal, the helper
brings that app forward again, so you don't need to refocus it yourself. The app's
window must be on the selected display. In display mode, `press_keys` goes through
the system, so shortcuts such as `cmd+tab` and `cmd+space` work.

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

Before typing or pressing keys, the helper brings the selected window forward
and waits up to five seconds for it to have focus. Keys are sent only to the
window's app, so system shortcuts such as `cmd+tab` don't apply in window mode.
Coordinates start at the top-left of the window, including its title bar.
Take a fresh screenshot if the layout changes. Keep the target still and
visible during a drag. The helper checks the path and releases the mouse button
if the window moves or the path becomes obstructed.

## The app running Vibe is off limits

The helper refuses to click, drag, scroll or type in the app that runs Vibe:
the terminal or editor that started it, found through the helper's parent
processes. Its windows hold your conversation and Vibe's approval prompts, so
only you may operate them. A drag may cross that app's windows but cannot start or end on
one. To see which apps are covered, run:

```sh
"$PWD/.native-build/window-control" protected
```

The helper can't find the app when Vibe runs in a detached `tmux` or `screen`
session, because those break the chain of parent processes. Run Vibe directly
in the terminal when you use these tools.

Screenshots are returned to Vibe as tool results. Select a display or window whose
contents you are comfortable sharing with the model.
