# /// script
# requires-python = ">=3.12"
# dependencies = ["mcp==2.3.0"]
# ///

"""Expose a user-selected macOS display or window over MCP stdio."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
from threading import Lock
from typing import Annotated, Any, Literal, override

from mcp.server.mcpserver import Context, Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import (
    CallToolResult,
    ImageContent,
    InputRequiredResult,
    TextContent,
    Tool as MCPTool,
    ToolAnnotations,
)
from pydantic import Field

Coordinate = Annotated[int, Field(ge=0, le=16_384, strict=True)]
Size = Annotated[int, Field(ge=16, le=16_384, strict=True)]
InputText = Annotated[str, Field(min_length=1, max_length=1000)]
KeySpec = Annotated[str, Field(min_length=1, max_length=60)]
HoldSpec = Annotated[str, Field(max_length=60)]
Notches = Annotated[int, Field(ge=-50, le=50, strict=True)]
Steps = Annotated[int, Field(ge=1, le=60, strict=True)]
Button = Literal["left", "right", "middle"]

_KEY_SPEC = re.compile(r"[a-z0-9+\-=\[\];',./\\`]+")
_HOLD_SPEC = re.compile(r"[a-z+]*")
# Screenshots and crops arrive as quality-70 JPEG. Vibe resends every earlier
# screenshot with each model request, so their size decides how slow it gets.
_JPEG_SIGNATURE = b"\xff\xd8\xff"
_INPUT = ToolAnnotations(
    read_only_hint=False, destructive_hint=True, open_world_hint=False
)


def _normalize(spec: str) -> str:
    return re.sub(r"\s+", "", spec).lower()


class _Helper:
    """Runs the Swift helper for one target, one action at a time."""

    def __init__(self, target: list[str]) -> None:
        self._target = target
        self._lock = Lock()
        # The app the last click or drag landed in. In display mode keyboard input
        # goes there, because Vibe's terminal is frontmost after the user approves.
        self.keyboard_pid = 0

    def run(self, *args: object, text: str = "") -> bytes:
        if not self._lock.acquire(blocking=False):
            raise ToolError(
                "Another computer-use action is running. Try again after it finishes."
            )
        try:
            result = subprocess.run(
                [*self._target, *(str(value) for value in args)],
                input=text.encode(),
                capture_output=True,
                check=False,
                timeout=20,
            )
        except subprocess.TimeoutExpired as exc:
            raise ToolError(
                f"{args[0]} timed out. Check the target before retrying."
            ) from exc
        except OSError as exc:
            raise ToolError(f"Cannot launch the macOS helper: {exc}") from exc
        finally:
            self._lock.release()
        if result.returncode:
            raise ToolError(
                result.stderr.decode(errors="replace").strip() or "The helper failed."
            )
        return result.stdout

    def run_pointer(self, *args: object) -> None:
        """Run a click or drag and remember the app it left frontmost."""
        try:
            pid = json.loads(self.run(*args))["frontmost"]
        except (ValueError, KeyError, TypeError):
            pid = 0
        self.keyboard_pid = pid if isinstance(pid, int) and pid > 0 else 0


class _StrictServer(MCPServer):
    """Refuses arguments a tool does not take instead of silently dropping them.

    A model that remembers an older schema (`from_x` for `drag`, say) then learns the
    current names from the error, rather than acting on defaults it did not intend.
    """

    @override
    async def list_tools(self) -> list[MCPTool]:
        tools = await super().list_tools()
        for tool in tools:
            tool.input_schema["additionalProperties"] = False
        return tools

    @override
    async def call_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        context: Context[Any, Any] | None = None,
    ) -> CallToolResult | InputRequiredResult:
        tool = next(
            (tool for tool in await self.list_tools() if tool.name == name), None
        )
        if tool is not None:
            known = set(tool.input_schema.get("properties", {}))
            if unknown := sorted(set(arguments) - known):
                raise ToolError(
                    f"{name} does not take {', '.join(unknown)}. "
                    f"Its arguments are {', '.join(sorted(known)) or 'none'}."
                )
        return await super().call_tool(name, arguments, context)


def build_server(target: list[str], label: Literal["display", "window"]) -> MCPServer:
    """Build the MCP server for one target.

    `target` is the helper command that selects it: `[helper, "display", ID]` or
    `[helper, WINDOW_ID, PID]`.
    """
    helper = _Helper(target)
    server = _StrictServer(
        "computer-use",
        instructions=(
            f"Use these tools for visible macOS actions on the selected {label}, such as moving a desktop "
            "icon. Take a screenshot, locate the requested target, perform one input action, and take a "
            "fresh screenshot to verify the result. Use the dimensions reported with the screenshot. "
            "For a small or crowded target, such as a desktop icon, take a cropped screenshot around it "
            "and convert its pixels to points as the crop's text describes before clicking or dragging. "
            "The top-left is (0, 0), x increases right, and y increases down. "
            "The app running Vibe is off limits to input. "
            "If the image is unavailable or the target is unclear, ask the user to make it visible."
        ),
    )
    _add_screenshot_tool(server, helper, label)
    _add_pointer_tools(server, helper, label)
    _add_keyboard_tools(server, helper, label)
    return server


def _add_screenshot_tool(
    server: MCPServer, helper: _Helper, label: Literal["display", "window"]
) -> None:
    @server.tool(
        description=(
            f"Capture an image and coordinate dimensions of the selected {label}. Use this first for visual "
            "tasks and again after an action to verify the change. The top-left is (0, 0), x increases "
            "right, and y increases down. Use the reported dimensions if the image is shown at a reduced "
            "size. To read a small target precisely, pass x, y, width and height in points to capture only "
            "that region; one up to 500 points on its long side is enlarged 2×. The result says how to "
            "turn its pixels back into points. Every screenshot stays in the conversation and slows each "
            "later step, so crop only the area you need and take one only after something changed."
        ),
        structured_output=False,
        annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False),
    )
    def screenshot(
        x: Annotated[
            Coordinate | None, Field(description="Left edge of a crop, in points.")
        ] = None,
        y: Annotated[
            Coordinate | None, Field(description="Top edge of a crop, in points.")
        ] = None,
        width: Annotated[
            Size | None, Field(description="Crop width in points, at least 16.")
        ] = None,
        height: Annotated[
            Size | None, Field(description="Crop height in points, at least 16.")
        ] = None,
    ) -> list[TextContent | ImageContent]:
        crop = (x, y, width, height)
        if any(value is None for value in crop) and any(
            value is not None for value in crop
        ):
            raise ToolError(
                "Pass all of x, y, width and height for a crop, or none of them."
            )
        args = [] if x is None else list(crop)
        line, _, data = helper.run("screenshot", *args).partition(b"\n")
        metadata = json.loads(line)
        if metadata.get("format") != "jpeg" or not data.startswith(_JPEG_SIGNATURE):
            raise ToolError("The macOS helper did not return a JPEG image.")
        return [
            TextContent(type="text", text=_describe_shot(metadata, label)),
            Image(data=data, format="jpeg").to_image_content(),
        ]


def _describe_shot(metadata: dict[str, Any], label: str) -> str:
    width, height = metadata["size"]
    if "region" not in metadata:
        return f"{width} × {height} {label} points. Origin (0, 0) is the top-left."
    left, top, crop_width, crop_height = metadata["region"]
    zoom = metadata["zoom"]
    scale = f"/{zoom}" if zoom != 1 else ""
    return (
        f"Crop of {label} points x {left}-{left + crop_width}, y {top}-{top + crop_height} "
        f"(the whole {label} is {width} × {height}), shown at {zoom}× "
        f"({crop_width * zoom} × {crop_height * zoom} pixels). Image pixel (px, py) is {label} point "
        f"({left} + px{scale}, {top} + py{scale}). Use {label} points for click and drag."
    )


def _add_pointer_tools(
    server: MCPServer, helper: _Helper, label: Literal["display", "window"]
) -> None:
    @server.tool(
        description=(
            f"Move the mouse to a point on the selected {label} and click. Choose integer x and y at the "
            "target's center from the latest screenshot. To enter text or press keys, click the intended "
            "field or window first."
        ),
        annotations=_INPUT,
    )
    def click(
        x: Coordinate,
        y: Coordinate,
        button: Annotated[Button, Field(description="Default left.")] = "left",
        double: Annotated[
            bool, Field(description="Double-click. Default false.")
        ] = False,
    ) -> str:
        helper.run_pointer("click", x, y, button, 2 if double else 1)
        kind = "Double-clicked" if double else "Clicked"
        suffix = "" if button == "left" else f" with the {button} button"
        return f"{kind} ({x}, {y}){suffix}."

    @server.tool(
        description=(
            f"Scroll the mouse wheel over a point on the selected {label}. Positive notches scroll up and "
            "negative notches scroll down. Take a screenshot afterward to see the new position."
        ),
        annotations=_INPUT,
    )
    def scroll(x: Coordinate, y: Coordinate, notches: Notches) -> str:
        if notches == 0:
            raise ToolError("notches must not be zero.")
        helper.run("scroll", x, y, notches)
        return (
            f"Scrolled {'up' if notches > 0 else 'down'} {abs(notches)} at ({x}, {y})."
        )

    @server.tool(
        description=(
            "Press a mouse button at one point, move to another while holding it, and release: drag a file "
            "icon, window, slider or scroll bar, select text, or draw a selection box. Use a recent "
            "screenshot for both integer points. For a desktop icon, start at the center of its icon and "
            "end on empty desktop space, clear of windows and other icons. The button is always released "
            "at the end. Take another screenshot to verify the result."
        ),
        annotations=_INPUT,
    )
    def drag(
        start_x: Coordinate,
        start_y: Coordinate,
        end_x: Coordinate,
        end_y: Coordinate,
        button: Annotated[Button, Field(description="Default left.")] = "left",
        hold: Annotated[
            HoldSpec,
            Field(
                description='Modifier keys held throughout, such as "alt" to copy a file or "cmd+shift". Default none.'
            ),
        ] = "",
        steps: Annotated[
            Steps | None,
            Field(
                description="How many small moves to make on the way (1-60). By default one per 24 points, at least 12."
            ),
        ] = None,
    ) -> str:
        modifiers = _normalize(hold)
        if not _HOLD_SPEC.fullmatch(modifiers):
            raise ToolError(
                'hold takes modifier keys joined with +, such as "shift" or "cmd+alt".'
            )
        helper.run_pointer(
            "drag", start_x, start_y, end_x, end_y, button, steps or 0, modifiers or "-"
        )
        held = f" holding {modifiers}" if modifiers else ""
        return f"Dragged from ({start_x}, {start_y}) to ({end_x}, {end_y}){held}."


def _add_keyboard_tools(
    server: MCPServer, helper: _Helper, label: Literal["display", "window"]
) -> None:
    if label == "display":
        note = (
            "Keyboard input goes to the app you last clicked or dragged in, which is brought to the "
            "front first. It never goes to the app running Vibe."
        )
    else:
        note = "The selected window is brought to the front first."

    @server.tool(
        description=(
            "Type literal text into the control that has keyboard focus. Click the intended field first. "
            f"Newlines press Enter and tabs press Tab. {note}"
        ),
        annotations=_INPUT,
    )
    def type_text(text: InputText) -> str:
        helper.run("type", helper.keyboard_pid, text=text)
        return f"Typed {len(text)} characters into the focused control."

    @server.tool(
        description=(
            "Press one key, optionally with modifiers, such as enter, esc, tab, space, backspace, delete "
            "(forward delete), up, pagedown, f5, cmd+s, cmd+shift+z or alt+left. Join keys with +. Use cmd "
            f"for Command, alt for Option and ctrl for Control. {note}"
        ),
        annotations=_INPUT,
    )
    def press_keys(keys: KeySpec) -> str:
        spec = _normalize(keys)
        if not _KEY_SPEC.fullmatch(spec):
            raise ToolError(
                "keys takes key names joined with +, such as enter or cmd+shift+z."
            )
        helper.run("keys", spec, helper.keyboard_pid)
        return f"Pressed {spec}."


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument(
        "--display", metavar="MAIN_OR_ID", help="'main' or a numeric display ID"
    )
    selection.add_argument("--window", type=int, help="Window ID, used with --pid")
    parser.add_argument("--pid", type=int, help="Process ID of the selected window")
    options = parser.parse_args()

    helper = str(options.helper.resolve())
    if options.display is not None:
        if options.pid is not None:
            parser.error("--pid is only used with --window")
        if options.display != "main" and not (
            options.display.isascii() and options.display.isdecimal()
        ):
            parser.error("--display must be 'main' or a numeric display ID")
        server = build_server([helper, "display", options.display], "display")
    else:
        if options.window <= 0 or options.pid is None or options.pid <= 0:
            parser.error("--window and --pid require positive numeric IDs")
        server = build_server([helper, str(options.window), str(options.pid)], "window")
    server.run()


if __name__ == "__main__":
    main()
