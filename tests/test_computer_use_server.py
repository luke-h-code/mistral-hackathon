from __future__ import annotations

import importlib.util
from pathlib import Path
import stat
from types import ModuleType
from typing import Any

from mcp.client.client import Client
from mcp.types import ImageContent, TextContent
import pytest

SERVER_SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "computer-use" / "server.py"
)

# Stands in for the Swift helper: records its arguments and stdin, then answers as
# the helper does for each action. `$3` is the action after `display main`.
_FAKE_HELPER = """#!/bin/sh
printf '%s\\n' "$*" >> "{log}"
case "$3" in
  screenshot)
    if [ -n "$4" ]; then
      printf '{{"size": [100, 50], "region": [%s, %s, 20, 16], "zoom": 2, "format": "jpeg"}}\\n' "$4" "$5"
      printf '\\377\\330\\377rest'
    else
      printf '{{"size": [100, 50], "format": "jpeg"}}\\n\\377\\330\\377rest'
    fi ;;
  click) printf '{{"frontmost": 4242}}\\n' ;;
  drag) printf '{{"frontmost": 0}}\\n' ;;
  type) cat > "{log}.stdin" ;;
  scroll) echo "Coordinates are outside the selected display." >&2; exit 1 ;;
esac
"""


def _load_server() -> ModuleType:
    spec = importlib.util.spec_from_file_location("computer_use_server", SERVER_SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def helper(tmp_path: Path) -> tuple[Path, Path]:
    log = tmp_path / "calls.log"
    script = tmp_path / "window-control"
    script.write_text(_FAKE_HELPER.format(log=log))
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


def _calls(log: Path) -> list[str]:
    return log.read_text().splitlines() if log.exists() else []


async def _call(
    helper: tuple[Path, Path], *calls: tuple[str, dict[str, Any]]
) -> list[Any]:
    server = _load_server().build_server([str(helper[0]), "display", "main"], "display")
    async with Client(server) as client:
        return [await client.call_tool(name, args) for name, args in calls]


@pytest.mark.asyncio
async def test_lists_the_pi_platform_computer_use_tools(
    helper: tuple[Path, Path],
) -> None:
    server = _load_server().build_server([str(helper[0]), "display", "main"], "display")
    async with Client(server) as client:
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}

    assert set(tools) == {
        "screenshot",
        "click",
        "type_text",
        "press_keys",
        "scroll",
        "drag",
    }
    read_only = {
        name
        for name, tool in tools.items()
        if tool.annotations and tool.annotations.read_only_hint
    }
    assert read_only == {"screenshot"}
    assert all(
        tool.input_schema["additionalProperties"] is False for tool in tools.values()
    )
    assert set(tools["drag"].input_schema["required"]) == {
        "start_x",
        "start_y",
        "end_x",
        "end_y",
    }


@pytest.mark.asyncio
async def test_screenshot_returns_dimensions_and_jpeg(
    helper: tuple[Path, Path],
) -> None:
    (result,) = await _call(helper, ("screenshot", {}))

    assert not result.is_error
    text, image = result.content
    assert isinstance(text, TextContent)
    assert text.text.startswith("100 × 50 display points")
    assert isinstance(image, ImageContent)
    assert image.mime_type == "image/jpeg"


@pytest.mark.asyncio
async def test_cropped_screenshot_says_how_to_convert_pixels_to_points(
    helper: tuple[Path, Path],
) -> None:
    (result,) = await _call(
        helper, ("screenshot", {"x": 70, "y": 30, "width": 40, "height": 40})
    )

    assert not result.is_error
    assert _calls(helper[1]) == ["display main screenshot 70 30 40 40"]
    text = result.content[0]
    assert isinstance(text, TextContent)
    # The helper trimmed the crop to 20 × 16 at the display's edge.
    assert "x 70-90, y 30-46" in text.text
    assert "(40 × 32 pixels)" in text.text
    assert "display point (70 + px/2, 30 + py/2)" in text.text
    image = result.content[1]
    assert isinstance(image, ImageContent)
    assert image.mime_type == "image/jpeg"


@pytest.mark.asyncio
async def test_unknown_arguments_are_rejected_with_the_real_names(
    helper: tuple[Path, Path],
) -> None:
    (result,) = await _call(
        helper,
        (
            "drag",
            {
                "from_x": 1,
                "from_y": 2,
                "start_x": 1,
                "start_y": 2,
                "end_x": 3,
                "end_y": 4,
            },
        ),
    )

    assert result.is_error
    assert _calls(helper[1]) == []
    text = result.content[0]
    assert isinstance(text, TextContent)
    assert "drag does not take from_x, from_y" in text.text
    assert "end_x" in text.text


@pytest.mark.asyncio
async def test_keyboard_input_goes_to_the_app_last_clicked(
    helper: tuple[Path, Path],
) -> None:
    results = await _call(
        helper,
        ("press_keys", {"keys": "cmd+s"}),
        ("click", {"x": 10, "y": 20, "button": "right", "double": True}),
        ("type_text", {"text": "hello\nworld"}),
        ("press_keys", {"keys": " Cmd + Shift + Z "}),
        ("drag", {"start_x": 1, "start_y": 2, "end_x": 3, "end_y": 4}),
        ("press_keys", {"keys": "enter"}),
    )

    assert not any(result.is_error for result in results)
    assert _calls(helper[1]) == [
        "display main keys cmd+s 0",
        "display main click 10 20 right 2",
        "display main type 4242",
        "display main keys cmd+shift+z 4242",
        "display main drag 1 2 3 4 left 0 -",
        "display main keys enter 0",
    ]
    assert Path(f"{helper[1]}.stdin").read_text() == "hello\nworld"


@pytest.mark.asyncio
async def test_drag_passes_button_modifiers_and_steps(
    helper: tuple[Path, Path],
) -> None:
    (result,) = await _call(
        helper,
        (
            "drag",
            {
                "start_x": 5,
                "start_y": 6,
                "end_x": 70,
                "end_y": 80,
                "button": "middle",
                "hold": "Alt + Shift",
                "steps": 30,
            },
        ),
    )

    assert not result.is_error
    assert _calls(helper[1]) == ["display main drag 5 6 70 80 middle 30 alt+shift"]


@pytest.mark.parametrize(
    ("name", "args"),
    [
        ("screenshot", {"x": 1, "y": 1}),
        ("screenshot", {"x": 1, "y": 1, "width": 8, "height": 40}),
        ("click", {"x": -1, "y": 0}),
        ("click", {"x": 0, "y": 20_000}),
        ("click", {"x": 1, "y": 1, "button": "back"}),
        ("scroll", {"x": 1, "y": 1, "notches": 0}),
        ("scroll", {"x": 1, "y": 1, "notches": 51}),
        ("press_keys", {"keys": "cmd+$(reboot)"}),
        ("type_text", {"text": ""}),
        (
            "drag",
            {"start_x": 1, "start_y": 1, "end_x": 2, "end_y": 2, "hold": "shift+1"},
        ),
        ("drag", {"start_x": 1, "start_y": 1, "end_x": 2, "end_y": 2, "steps": 61}),
    ],
)
@pytest.mark.asyncio
async def test_invalid_input_is_rejected_before_the_helper_runs(
    helper: tuple[Path, Path], name: str, args: dict[str, Any]
) -> None:
    (result,) = await _call(helper, (name, args))

    assert result.is_error
    assert _calls(helper[1]) == []


@pytest.mark.asyncio
async def test_helper_errors_are_reported_to_the_model(
    helper: tuple[Path, Path],
) -> None:
    (result,) = await _call(helper, ("scroll", {"x": 1, "y": 1, "notches": -3}))

    assert result.is_error
    (content,) = result.content
    assert isinstance(content, TextContent)
    assert "outside the selected display" in content.text
