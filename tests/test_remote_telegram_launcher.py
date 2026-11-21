from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

LAUNCHER = Path(__file__).resolve().parents[1] / "remote" / "telegram_computer_use.py"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("telegram_computer_use", LAUNCHER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_REGISTRATION: dict[str, Any] = {
    "name": "computer-use",
    "transport": "stdio",
    "command": "/usr/local/bin/uv",
    "args": ["run", "--script", "server.py", "--display", "main"],
}


def test_a_registered_server_that_asks_is_ready() -> None:
    config = {
        "mcp_servers": [_REGISTRATION],
        # A read-only screenshot may be approved automatically.
        "tools": {"computer-use_screenshot": {"permission": "always"}},
    }

    problems, registration = _load().check_config(config)

    assert problems == []
    assert registration == [
        "/usr/local/bin/uv",
        "run",
        "--script",
        "server.py",
        "--display",
        "main",
    ]


def test_auto_approved_input_tools_would_never_reach_telegram() -> None:
    config = {
        "mcp_servers": [_REGISTRATION],
        "tools": {
            "computer-use_click": {"permission": "always"},
            "computer-use_press_keys": {"permission": "Always"},
            "computer-use_type_text": {"permission": "ask"},
        },
    }

    (problem,), _ = _load().check_config(config)

    assert "[tools.computer-use_click]" in problem
    assert "[tools.computer-use_press_keys]" in problem
    assert "type_text" not in problem
    assert 'permission = "ask"' in problem


def test_an_unregistered_server_is_reported() -> None:
    problems, registration = _load().check_config({"mcp_servers": []})

    assert registration is None
    assert "No MCP server named 'computer-use'" in problems[0]


@pytest.mark.parametrize("value", ["", "abc", "-5", "0", "12.5"])
def test_chat_id_must_name_one_private_chat(value: str) -> None:
    with pytest.raises(ValueError, match="positive numeric id"):
        _load().chat_id(value)


def test_chat_id_accepts_a_user_id() -> None:
    assert _load().chat_id("123456789") == 123456789


def test_env_file_reads_values_and_ignores_comments(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# Telegram\n"
        "TELEGRAM_BOT_TOKEN='123:abc'\n"
        'export TELEGRAM_CHAT_ID="42"\n'
        "\n"
        "BROKEN LINE\n"
    )

    values = _load().load_env_file(env_file)

    assert values == {"TELEGRAM_BOT_TOKEN": "123:abc", "TELEGRAM_CHAT_ID": "42"}
    assert _load().load_env_file(tmp_path / "missing") == {}
