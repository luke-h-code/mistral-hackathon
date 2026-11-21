// The helper's decisions that need no screen, events or permissions, kept apart so
// tests/computer_use/LogicTests.swift can check them on any Mac.

import CoreGraphics
import Foundation

struct ControlError: LocalizedError, Equatable {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

// MARK: - Keyboard target

/// What to do before sending keyboard input. Input goes to whatever has focus,
/// popups and dialogs included; nothing about windows or text fields is checked.
enum KeyboardTarget: Equatable {
    /// Send to the app that has focus now.
    case current
    /// Bring this app back to the front first.
    case activate(pid_t)
}

/// `preferred` is the app the model last clicked or dragged in (0 if none yet).
/// Approving a call in Vibe's terminal moves focus there, so that app is brought
/// back first; otherwise the input would land in Vibe's own prompt.
func keyboardTarget(frontmost: pid_t, preferred: pid_t, preferredRunning: Bool) -> KeyboardTarget {
    guard preferred > 0, preferred != frontmost, preferredRunning else { return .current }
    return .activate(preferred)
}

// MARK: - Typing

enum TypedKey: Equatable {
    /// A key pressed by its virtual key code.
    case key(CGKeyCode)
    /// One character sent as Unicode, whatever the keyboard layout.
    case unicode([UInt16])
}

/// The key events for a piece of text: newlines press Return, tabs press Tab,
/// and a lone carriage return is dropped.
func typedKeys(_ text: String) -> [TypedKey] {
    text.compactMap { character in
        switch character {
        case "\n", "\r\n": return .key(36)
        case "\t": return .key(48)
        case "\r": return nil
        default: return .unicode(Array(String(character).utf16))
        }
    }
}

func validateText(_ data: Data) throws -> String {
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty, text.utf16.count <= 2_000
    else { throw ControlError("Provide valid text of at most 2,000 UTF-16 units.") }
    guard text.allSatisfy({ String($0).utf16.count <= 20 }) else {
        throw ControlError("A text character is too long to send as a keyboard event.")
    }
    return text
}

// MARK: - Keys

struct Modifier: Equatable {
    let flag: CGEventFlags
    let keyCode: CGKeyCode

    static let control = Modifier(flag: .maskControl, keyCode: 59)
    static let option = Modifier(flag: .maskAlternate, keyCode: 58)
    static let shift = Modifier(flag: .maskShift, keyCode: 56)
    static let command = Modifier(flag: .maskCommand, keyCode: 55)
    /// The order modifiers are pressed in, and released in reverse.
    static let order = [control, option, shift, command]

    init(flag: CGEventFlags, keyCode: CGKeyCode) {
        self.flag = flag
        self.keyCode = keyCode
    }

    init?(_ name: Substring) {
        switch name {
        case "ctrl", "control": self = .control
        case "alt", "option", "opt": self = .option
        case "shift": self = .shift
        case "cmd", "command", "win", "super", "meta": self = .command
        default: return nil
        }
    }

    static func == (lhs: Modifier, rhs: Modifier) -> Bool { lhs.keyCode == rhs.keyCode }

    /// Modifiers joined with `+`, such as `shift` or `cmd+alt`; `-` means none.
    static func parseHold(_ spec: String) throws -> [Modifier] {
        guard spec != "-" else { return [] }
        var held: [Modifier] = []
        for token in spec.split(separator: "+", omittingEmptySubsequences: false) {
            guard let modifier = Modifier(token) else {
                throw ControlError("hold takes modifier keys only: cmd, ctrl, alt or shift, joined with +.")
            }
            held.append(modifier)
        }
        return order.filter(held.contains)
    }
}

struct KeyCombo: Equatable {
    let code: CGKeyCode
    let flags: CGEventFlags

    static let namedKeys: [String: CGKeyCode] = [
        "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "esc": 53, "escape": 53,
        "delete": 117, "del": 117, "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pgup": 116, "pagedown": 121, "pgdn": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// ANSI keyboard characters by virtual key code (Carbon's kVK_ANSI_*); NUL marks
    /// codes that are not single characters.
    static let ansiKeys: [Character: CGKeyCode] = {
        let layout = Array("asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.\0\0`")
        var keys: [Character: CGKeyCode] = [:]
        for (code, character) in layout.enumerated() where character != "\0" {
            keys[character] = CGKeyCode(code)
        }
        return keys
    }()

    /// One key with optional modifiers, such as `enter`, `cmd+s` or `cmd+shift+4`.
    static func parse(_ spec: String) throws -> KeyCombo {
        var flags = CGEventFlags()
        var code: CGKeyCode?
        for token in spec.split(separator: "+", omittingEmptySubsequences: false) {
            if let modifier = Modifier(token) {
                flags.insert(modifier.flag)
                continue
            }
            let key = namedKeys[String(token)] ?? (token.count == 1 ? ansiKeys[token.first!] : nil)
            guard let key else {
                throw ControlError(
                    "Unknown key \"\(token)\". Use names such as cmd, ctrl, alt, shift, enter, esc, tab, "
                        + "space, backspace, delete, up, f1-f12, a or 1, joined with +."
                )
            }
            guard code == nil else {
                throw ControlError("Press one key at a time, with any modifiers, such as cmd+s.")
            }
            code = key
        }
        guard let code else { throw ControlError("Name a key to press besides the modifiers.") }
        return KeyCombo(code: code, flags: flags)
    }
}

// MARK: - Mouse buttons

enum Button: String {
    case left, right, middle

    var cg: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var down: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var up: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var dragged: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    static func parse(_ name: String) throws -> Button {
        guard let button = Button(rawValue: name) else { throw ControlError("button is left, right or middle.") }
        return button
    }
}

// MARK: - Screenshot crops

/// A crop from `x y width height` arguments, in the target's points and trimmed to
/// its edges. No arguments means the whole target.
func cropRegion(_ args: [String], within size: CGSize, label: String) throws -> CGRect? {
    guard !args.isEmpty else { return nil }
    let values = args.compactMap { Int($0) }
    guard values.count == 4, args.count == 4, values[2] > 0, values[3] > 0
    else { throw ControlError("A screenshot region is x, y, width and height in whole points.") }
    let bounds = CGRect(x: 0, y: 0, width: size.width.rounded(.up), height: size.height.rounded(.up))
    let crop = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).intersection(bounds)
    guard !crop.isNull, crop.width >= 16, crop.height >= 16 else {
        throw ControlError(
            "The region must overlap the selected \(label) (\(Int(bounds.width)) × \(Int(bounds.height)) points) "
                + "by at least 16 × 16 points."
        )
    }
    return crop
}

/// Pixels per point for a crop. A small crop is enlarged so its targets are
/// legible; on a Retina display the extra pixels are real detail. A larger crop is
/// already legible, and enlarging it would only make every later request heavier.
func cropZoom(_ region: CGRect) -> Int {
    max(region.width, region.height) <= 500 ? 2 : 1
}
