# Approve computer use from Telegram

Run a Vibe session that uses the [computer-use MCP server](computer-use-mcp.md)
and asks for approval in Telegram. You start the session and give it a task from
a Telegram chat; each click, drag, scroll, key press or piece of typed text the
model wants to send arrives in that chat as a card with **Allow once** and
**Deny** buttons.

```
Telegram ──▶ Baton Telegram bridge ──WebSocket──▶ Baton server ──ACP──▶ vibe-acp ──▶ computer-use MCP
```

It uses [Baton](https://github.com/sneldao/baton), included under
`remote/baton/`, and its Telegram bridge. Vibe runs on your Mac as usual;
Telegram only carries the task, the approval cards and your answers.

> **Release gate.** Baton's own review
> ([remote/baton/docs/telegram-integration-review.md](../remote/baton/docs/telegram-integration-review.md))
> keeps the live Telegram integration paused until its end-to-end checks pass
> and one rehearsal on a real phone succeeds. Agree with Baton's maintainers
> before using it with a real bot, and use a dedicated bot and a test Mac.

## Before you start

1. Build and register the computer-use MCP server as described in
   [computer-use-mcp.md](computer-use-mcp.md), and grant Screen Recording and
   Accessibility to the terminal you will run Baton from.
2. Make Vibe ask before each input action. In `~/.vibe/config.toml`, remove any
   `permission = "always"` from these sections, or set it to `"ask"`:
   `[tools.computer-use_click]`, `[tools.computer-use_drag]`,
   `[tools.computer-use_scroll]`, `[tools.computer-use_type_text]` and
   `[tools.computer-use_press_keys]`. A tool Vibe approves by itself never
   reaches Telegram. `screenshot` only reads the screen and may stay on
   `"always"`.

## Set up the Telegram bot

1. In Telegram, message **@BotFather**, send `/newbot` and follow the steps.
   It gives you a bot token. Treat it like a password.
2. Send any message to your new bot from your own account.
3. Find your chat id, which for a private chat is your Telegram user id:

   ```sh
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | grep -o '"chat":{"id":[0-9]*'
   ```

4. Create `remote/baton/.env` (it is git-ignored):

   ```sh
   TELEGRAM_BOT_TOKEN=<token from BotFather>
   TELEGRAM_CHAT_ID=<your chat id>
   ```

Only that one private chat can use the bot: Baton checks every message and
button press against it, and `/start` cannot add anyone else.

## Run a session

From the repository root:

```sh
uv run python remote/telegram_computer_use.py
```

The launcher checks that the computer-use server is registered and that its
input tools ask first, warns if Vibe's cached tool list is out of date, then
starts Baton's server on this checkout's `vibe-acp` and the Telegram bridge.
Press `Ctrl+C` to stop both.

In your chat with the bot:

1. Send `/start` to confirm the link.
2. Send `/new` to start a session, then your task, for example
   "Take a screenshot, open Firefox and go to wikipedia.org".
3. Approve or deny each card. A card shows the tool and its arguments, such as
   the coordinates of a click or the text to type, and Baton's one-line risk
   summary. Once you answer, it turns into a receipt showing your decision.
4. `/stop` cancels the running turn, `/sessions` resumes an earlier session and
   `/status` shows the bridge's state.

Options:

| Option | Default | Use |
| --- | --- | --- |
| `--cwd DIR` | `remote/baton/demo` | Folder the Vibe sessions work in. Vibe's file and shell tools act here, so keep it a disposable folder. |
| `--port N` | `8765` | Port for Baton's server. |
| `--env-file FILE` | `remote/baton/.env` | Where to read the Telegram settings. Environment variables take precedence. |

`MISTRAL_API_KEY` is read from the environment or, on macOS, from the keychain
entry Vibe stores. Baton uses it for its one-line risk summaries on each card.

## What goes where

- **Telegram** receives your task and every card: the tool name and its
  arguments, including any text the model wants to type. It does not receive
  screenshots.
- **Mistral** receives the tool arguments for Baton's risk summaries, in
  addition to the session itself.
- **Baton's web page** also runs, on port 8765 on every network interface,
  protected by a random access token printed at startup. Anyone on your network
  with the token can approve requests there too.
- Approving on your phone does not move focus on the Mac, so keyboard input
  goes straight to the app the model last clicked. See the
  [security notes](computer-use-mcp.md#security-and-limitations) for what the
  computer-use tools can reach.

## Update Baton

`remote/baton/` is a squashed git subtree of `sneldao/baton`. To take its latest
changes:

```sh
git subtree pull --prefix=remote/baton https://github.com/sneldao/baton.git main --squash
```

Make changes to Baton in its own repository rather than here, so pulls stay
clean. Baton's tests run with its own dependencies:

```sh
cd remote/baton
uv run --with pytest --with pytest-asyncio pytest tests -c pyproject.toml -o addopts=""
```
