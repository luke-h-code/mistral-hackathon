// Tests for scripts/computer-use/Logic.swift. They need only the Command Line Tools:
//   swiftc -parse-as-library scripts/computer-use/Logic.swift \
//     tests/computer_use/LogicTests.swift -o logic-tests && ./logic-tests
// tests/test_computer_use_helper.py runs them under pytest on macOS.

import CoreGraphics
import Foundation

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    do {
        if try condition() {
            passed += 1
            return
        }
        print("FAIL: \(name)")
    } catch {
        print("FAIL: \(name): threw \(error.localizedDescription)")
    }
    failures += 1
}

func throwsError(_ body: () throws -> Any?, containing text: String) -> Bool {
    do {
        _ = try body()
        return false
    } catch {
        return error.localizedDescription.contains(text)
    }
}

let firefox: pid_t = 501
let terminal: pid_t = 777

func testKeyboardTarget() {
    // The popup-focus regression: Firefox is frontmost with its location prompt
    // open. Keys go to it as they are; no window or text field has to match.
    check(
        keyboardTarget(frontmost: firefox, preferred: firefox, preferredRunning: true) == .current,
        "a popup in the frontmost app takes keys without any focus check"
    )
    check(
        keyboardTarget(frontmost: terminal, preferred: firefox, preferredRunning: true) == .activate(firefox),
        "after approval in Vibe's terminal, the app last clicked is brought back"
    )
    check(
        keyboardTarget(frontmost: terminal, preferred: 0, preferredRunning: false) == .current,
        "before any click, keys go to whatever has focus"
    )
    check(
        keyboardTarget(frontmost: terminal, preferred: firefox, preferredRunning: false) == .current,
        "an app that has quit is not brought back"
    )
    check(
        keyboardTarget(frontmost: terminal, preferred: terminal, preferredRunning: true) == .current,
        "the app running Vibe is not off limits: clicking it sends keys there"
    )
}

func testTypedKeys() {
    check(
        typedKeys("a\nb\tc\r\nd\r") == [
            .unicode([97]), .key(36), .unicode([98]), .key(48), .unicode([99]), .key(36), .unicode([100]),
        ],
        "newlines press Return, tabs press Tab, lone carriage returns are dropped"
    )
    check(typedKeys("é") == [.unicode([233])], "accented characters are sent as Unicode")
    check(typedKeys("👍") == [.unicode([0xD83D, 0xDC4D])], "emoji are sent as one UTF-16 pair")
    check((try? validateText(Data("hi".utf8))) == "hi", "short text is accepted")
    check(throwsError({ try validateText(Data()) }, containing: "at most 2,000"), "empty text is refused")
    check(
        throwsError({ try validateText(Data(String(repeating: "a", count: 2_001).utf8)) }, containing: "at most"),
        "text over 2,000 units is refused"
    )
}

func testKeyCombo() {
    check((try? KeyCombo.parse("escape")) == KeyCombo(code: 53, flags: []), "escape")
    check((try? KeyCombo.parse("enter")) == KeyCombo(code: 36, flags: []), "enter")
    check(
        (try? KeyCombo.parse("cmd+shift+z")) == KeyCombo(code: 6, flags: [.maskCommand, .maskShift]),
        "cmd+shift+z"
    )
    check((try? KeyCombo.parse("alt+left")) == KeyCombo(code: 123, flags: [.maskAlternate]), "alt+left")
    check((try? KeyCombo.parse("cmd+-")) == KeyCombo(code: 27, flags: [.maskCommand]), "cmd+- uses the minus key")
    check(throwsError({ try KeyCombo.parse("cmd+bogus") }, containing: "Unknown key \"bogus\""), "unknown key")
    check(throwsError({ try KeyCombo.parse("cmd+a+b") }, containing: "one key at a time"), "two keys")
    check(throwsError({ try KeyCombo.parse("cmd+shift") }, containing: "besides the modifiers"), "modifiers only")
}

func testHold() {
    check((try? Modifier.parseHold("-")) == [], "- holds nothing")
    check(
        (try? Modifier.parseHold("cmd+shift")) == [.shift, .command],
        "modifiers are pressed in a fixed order"
    )
    check(throwsError({ try Modifier.parseHold("shift+q") }, containing: "modifier keys only"), "q is not a modifier")
}

func testCrop() {
    let display = CGSize(width: 1710, height: 1107)
    check((try? cropRegion([], within: display, label: "display")) == .some(nil), "no arguments is the whole display")
    check(
        (try? cropRegion(["200", "280", "700", "600"], within: display, label: "display"))
            == CGRect(x: 200, y: 280, width: 700, height: 600),
        "a crop inside the display is kept"
    )
    check(
        (try? cropRegion(["1600", "1000", "400", "400"], within: display, label: "display"))
            == CGRect(x: 1600, y: 1000, width: 110, height: 107),
        "a crop past the edge is trimmed"
    )
    check(
        throwsError({ try cropRegion(["1700", "0", "50", "50"], within: display, label: "display") },
                    containing: "at least 16 × 16"),
        "a crop with too little overlap is refused"
    )
    check(
        throwsError({ try cropRegion(["1", "2", "3"], within: display, label: "display") },
                    containing: "x, y, width and height"),
        "a crop needs four numbers"
    )
    check(cropZoom(CGRect(x: 0, y: 0, width: 500, height: 320)) == 2, "a crop up to 500 points is enlarged")
    check(cropZoom(CGRect(x: 0, y: 0, width: 700, height: 600)) == 1, "a larger crop is not enlarged")
}

func testButton() {
    check((try? Button.parse("right")) == .right, "right button")
    check(throwsError({ try Button.parse("back") }, containing: "left, right or middle"), "unknown button")
}

@main
struct LogicTests {
    static func main() {
        testKeyboardTarget()
        testTypedKeys()
        testKeyCombo()
        testHold()
        testCrop()
        testButton()
        print("\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
