#!/usr/bin/env python3
"""Run a computer-use Vibe session that asks for approval on Telegram.

Starts Baton's server (remote/baton) on this checkout's vibe-acp, then Baton's
Telegram bridge. In the authorized Telegram chat, send /new and then a request;
every computer-use action the model wants to take arrives as a card with
"Allow once" and "Deny" buttons.

    uv run python remote/telegram_computer_use.py [--cwd DIR] [--port 8765]

Needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, from the environment or
remote/baton/.env, and the computer-use MCP server registered in Vibe with its
input tools set to ask. See docs/remote-telegram.md.
"""

from __future__ import annotations

import argparse
from collections.abc import Mapping
import os
from pathlib import Path
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import time
import tomllib
from typing import Any
import urllib.error
import urllib.request

DESCRIPTION = "Run a computer-use Vibe session that asks for approval on Telegram."
REPO = Path(__file__).resolve().parents[1]
BATON = REPO / "remote" / "baton"
SERVER_NAME = "computer-use"
# Input tools: each must reach the operator, so none may be auto-approved.
INPUT_TOOLS = ("click", "drag", "scroll", "type_text", "press_keys")


def vibe_home() -> Path:
    return Path(os.environ.get("VIBE_HOME") or Path.home() / ".vibe").expanduser()


def load_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE lines from a .env file; comments, blanks and quotes handled."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.removeprefix("export ").partition("=")
        value = value.strip()
        for quote in ('"', "'"):
            if value.startswith(quote) and value.endswith(quote) and value != quote:
                value = value[1:-1]
        values[key.strip()] = value
    return values


def check_config(config: Mapping[str, Any]) -> tuple[list[str], list[str] | None]:
    """Problems that would stop approvals reaching Telegram, and the registration.

    Returns the problems and the registered server's command line (command then
    arguments), or None when the server is not registered.
    """
    problems: list[str] = []
    servers = config.get("mcp_servers") or []
    server = next(
        (s for s in servers if isinstance(s, dict) and s.get("name") == SERVER_NAME),
        None,
    )
    registration: list[str] | None = None
    if server is None:
        problems.append(
            f"No MCP server named {SERVER_NAME!r} is registered in Vibe. "
            "Register it as docs/computer-use-mcp.md describes."
        )
    elif server.get("transport") == "stdio" and server.get("command"):
        registration = [str(server["command"]), *map(str, server.get("args") or [])]
    tools = config.get("tools") or {}
    auto = [
        name
        for name in INPUT_TOOLS
        if str((tools.get(f"{SERVER_NAME}_{name}") or {}).get("permission", "")).lower()
        == "always"
    ]
    if auto:
        listed = ", ".join(f"[tools.{SERVER_NAME}_{name}]" for name in auto)
        problems.append(
            f"Vibe approves these computer-use tools without asking, so they would "
            f'never reach Telegram: {listed}. Set permission = "ask" for each in '
            "~/.vibe/config.toml, or remove the section."
        )
    return problems, registration


def chat_id(value: str) -> int:
    """TELEGRAM_CHAT_ID: the positive numeric id of one private chat."""
    if not value.isdecimal() or int(value) <= 0:
        raise ValueError(
            "TELEGRAM_CHAT_ID must be the positive numeric id of your private chat "
            "with the bot (the same as your Telegram user id)."
        )
    return int(value)


def keychain_api_key() -> str | None:
    """The Mistral key Vibe stored in the macOS keychain, as Baton's run.sh reads it."""
    if sys.platform != "darwin" or shutil.which("security") is None:
        return None
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s",
            "ai.mistral.vibe",
            "-a",
            "MISTRAL_API_KEY",
            "-w",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def warn_if_cache_stale(registration: list[str]) -> None:
    """Run the computer-use server's --check-cache with its registered arguments."""
    result = subprocess.run(
        [*registration, "--check-cache"],
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    if result.returncode != 0:
        print("Warning: Vibe's cached computer-use tool list is out of date:")
        print(result.stdout.strip() or result.stderr.strip())
        print("Quit any running Vibe and rerun that check with --clear.\n")


def wait_until_up(url: str, process: subprocess.Popen[bytes], seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Baton's server exited with code {process.returncode}.")
        try:
            urllib.request.urlopen(url, timeout=2).close()
            return
        except urllib.error.HTTPError:
            return  # it answered, even if only to refuse an unauthenticated request
        except OSError:
            time.sleep(0.5)
    raise RuntimeError(f"Baton's server did not answer on {url} in {seconds:.0f}s.")


def stop(processes: list[subprocess.Popen[bytes]]) -> None:
    """Stop the process groups this script started, and only those."""
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    for process in processes:
        try:
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)


def run(env: dict[str, str], workdir: Path, port: int) -> int:
    """Start Baton's server, then its Telegram bridge, and wait until one stops."""
    http = f"http://127.0.0.1:{port}"
    uv = ["uv", "run", "--project", str(BATON), "python", "-u"]
    processes: list[subprocess.Popen[bytes]] = []
    try:
        server = subprocess.Popen(
            [*uv, str(BATON / "server.py")],
            cwd=workdir,
            env=env,
            start_new_session=True,
        )
        processes.append(server)
        wait_until_up(f"{http}/", server, seconds=60)
        processes.append(
            subprocess.Popen(
                [*uv, str(BATON / "tools" / "telegram_bridge.py")],
                cwd=BATON,
                env=env,
                start_new_session=True,
            )
        )
        print(
            f"\nBaton is up, working in {workdir}.\n"
            "In your Telegram chat with the bot: send /start, then /new, then your "
            "request.\nEach computer-use action arrives as a card: Allow once or "
            "Deny. /stop cancels a turn.\nPress Ctrl+C here to stop Baton.\n"
        )
        while all(process.poll() is None for process in processes):
            time.sleep(0.5)
        failed = next(p for p in processes if p.poll() is not None)
        name = "server" if failed is server else "Telegram bridge"
        print(f"Baton's {name} exited with code {failed.returncode}.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    finally:
        stop(processes)


def main() -> int:
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument(
        "--cwd",
        type=Path,
        default=BATON / "demo",
        help="Folder the Vibe sessions work in (default: Baton's sacrificial demo repo).",
    )
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--env-file", type=Path, default=BATON / ".env")
    options = parser.parse_args()

    env = {**load_env_file(options.env_file), **os.environ}
    try:
        operator = chat_id(env.get("TELEGRAM_CHAT_ID", ""))
    except ValueError as exc:
        parser.error(str(exc))
    if not env.get("TELEGRAM_BOT_TOKEN"):
        parser.error(f"Set TELEGRAM_BOT_TOKEN (from @BotFather) in {options.env_file}.")

    config_path = vibe_home() / "config.toml"
    config = tomllib.loads(config_path.read_text()) if config_path.is_file() else {}
    problems, registration = check_config(config)
    for problem in problems:
        print(f"Error: {problem}", file=sys.stderr)
    if problems:
        return 2
    if registration:
        warn_if_cache_stale(registration)

    if not env.get("MISTRAL_API_KEY") and (key := keychain_api_key()):
        env["MISTRAL_API_KEY"] = key
    env |= {
        "BATON_TOKEN": env.get("BATON_TOKEN") or secrets.token_urlsafe(16),
        "PORT": str(options.port),
        "VIBE_ACP_CMD": f"uv run --directory {shlex.quote(str(REPO))} vibe-acp",
        "BATON_WS": f"ws://127.0.0.1:{options.port}/ws",
        "BATON_HTTP": f"http://127.0.0.1:{options.port}",
        "TELEGRAM_CHAT_ID": str(operator),
    }
    workdir = options.cwd.resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    return run(env, workdir, options.port)


if __name__ == "__main__":
    raise SystemExit(main())
