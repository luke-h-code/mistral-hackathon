"""Build the computer-use Swift helper and run its tests (macOS only).

The checks against the built helper use arguments it refuses before posting any
event, so they send no input and need no Accessibility permission.
"""

from __future__ import annotations

from pathlib import Path
import platform
import shutil
import subprocess
import sys

import pytest

pytestmark = [
    pytest.mark.skipif(
        sys.platform != "darwin" or shutil.which("swiftc") is None,
        reason="the computer-use helper builds only on macOS with swiftc",
    ),
    # Compiling Swift takes longer than the suite's default timeout.
    pytest.mark.timeout(300),
]

_REPO = Path(__file__).resolve().parents[1]
_SOURCES = _REPO / "scripts" / "computer-use"
_TESTS = _REPO / "tests" / "computer_use"


def _swiftc(output: Path, *sources: Path) -> None:
    target = f"{platform.machine()}-apple-macosx14.0"
    subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            "-target",
            target,
            *map(str, sources),
            "-o",
            str(output),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


@pytest.fixture(scope="module")
def helper(tmp_path_factory: pytest.TempPathFactory) -> Path:
    output = tmp_path_factory.mktemp("helper") / "window-control"
    _swiftc(output, _SOURCES / "Logic.swift", _SOURCES / "WindowControl.swift")
    return output


def test_logic_tests_pass(tmp_path: Path) -> None:
    runner = tmp_path / "logic-tests"
    _swiftc(runner, _SOURCES / "Logic.swift", _TESTS / "LogicTests.swift")

    result = subprocess.run([str(runner)], capture_output=True, text=True, check=False)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout


@pytest.mark.parametrize(
    ("args", "message"),
    [
        (["click", "99999", "5", "left", "1"], "outside the selected display"),
        (["click", "5", "5", "back", "1"], "left, right or middle"),
        (["scroll", "5", "5", "0"], "non-zero"),
        (["drag", "1", "1", "2", "2", "left", "0", "shift+q"], "modifier keys only"),
        (["keys", "cmd+bogus", "0"], 'Unknown key "bogus"'),
        (["screenshot", "1", "2", "3"], "x, y, width and height"),
    ],
)
def test_helper_refuses_bad_arguments_before_any_input(
    helper: Path, args: list[str], message: str
) -> None:
    result = subprocess.run(
        [str(helper), "display", "main", *args],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert message in result.stderr
