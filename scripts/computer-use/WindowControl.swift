import AppKit
import ApplicationServices
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ControlError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

// MARK: - The app running Vibe

/// Processes the model may not click, drag on, scroll or type into: the terminal or
/// app that runs Vibe, found through this helper's ancestors. Its windows hold the
/// conversation and Vibe's approval prompts, so only the user may operate them.
enum Protected {
    static let pids: Set<pid_t> = compute()
    static let message = "That is the app running Vibe. Only the user may operate it."

    static func contains(_ pid: pid_t) -> Bool { pid > 0 && pids.contains(pid) }

    private static func compute() -> Set<pid_t> {
        var ancestors = Set<pid_t>()
        var bundles = Set<String>()
        var pid = getppid()
        while pid > 1, ancestors.insert(pid).inserted {
            if let bundle = outerBundle(of: pid) { bundles.insert(bundle) }
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        // A terminal inside an app (VS Code, for example) runs in a helper process;
        // the windows belong to the app's main process in the same bundle.
        var result = ancestors
        for app in NSWorkspace.shared.runningApplications {
            if let path = app.bundleURL?.standardizedFileURL.path, bundles.contains(path) {
                result.insert(app.processIdentifier)
            }
        }
        return result
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func outerBundle(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let end = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<end.lowerBound]) + ".app").standardizedFileURL.path
    }
}

func frontmostPID() -> pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
}

// MARK: - Windows

struct Window {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let frame: CGRect
    let layer: Int

    static func onScreen() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        return (entries ?? []).compactMap { entry in
            guard
                let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty
            else { return nil }
            return Window(
                id: id, pid: pid,
                owner: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String ?? "",
                frame: frame, layer: layer
            )
        }
    }

    static func selected(_ id: CGWindowID, _ pid: pid_t, in windows: [Window]) throws -> Window {
        guard let window = windows.first(where: { $0.id == id && $0.pid == pid && $0.layer == 0 })
        else { throw ControlError("The selected window is closed, minimized, or off screen.") }
        return window
    }

    func checkPointer(_ point: CGPoint, in windows: [Window]) throws {
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 0, nil, &displayCount) == .success, displayCount > 0
        else { throw ControlError("The requested point is outside the visible displays.") }
        let covering = windows.filter { $0.layer >= 0 && $0.frame.contains(point) }
        guard covering.first(where: { $0.layer == 0 })?.id == id else {
            throw ControlError("The target point is covered. Bring the selected window forward.")
        }
        guard covering.first?.id != id else { return }

        // The Dock and other overlays can cover the screen with transparent windows.
        guard hitTest(point) == pid
        else { throw ControlError("The target point is covered. Bring the selected window forward.") }
    }

    func checkFocus() throws {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard frontmostPID() == pid,
              let focused = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              matches(focused as! AXUIElement),
              Window.onScreen().first(where: { $0.pid == pid && $0.layer == 0 })?.id == id
        else { throw ControlError("Focus a text control in the selected window before typing.") }
    }

    /// Whether an accessibility window element has this window's frame.
    func matches(_ element: AXUIElement) -> Bool {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            let position = attribute(element, kAXPositionAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(),
            let dimensions = attribute(element, kAXSizeAttribute),
            CFGetTypeID(dimensions) == AXValueGetTypeID(),
            AXValueGetValue(position as! AXValue, .cgPoint, &origin),
            AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
        else { return false }
        return abs(origin.x - frame.minX) <= 1 && abs(origin.y - frame.minY) <= 1
            && abs(size.width - frame.width) <= 1 && abs(size.height - frame.height) <= 1
    }

    /// Bring this window's app to the front and raise this window above its others.
    func bringForward() {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
           let element = windows.first(where: matches) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        activate(pid)
    }
}

/// The process that would receive a mouse event at a point, or 0 if unknown.
func hitTest(_ point: CGPoint) -> pid_t {
    let desktop = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(desktop, 0.25)
    var element: AXUIElement?
    var pid: pid_t = 0
    guard AXUIElementCopyElementAtPosition(desktop, Float(point.x), Float(point.y), &element) == .success,
          let element, AXUIElementGetPid(element, &pid) == .success
    else { return 0 }
    return pid
}

func checkNotProtected(_ point: CGPoint, windows: [Window]) throws {
    let hit = hitTest(point)
    let top = windows.first { $0.layer == 0 && $0.frame.contains(point) }
    if Protected.contains(hit) || (hit == 0 && top.map { Protected.contains($0.pid) } == true) {
        throw ControlError(Protected.message)
    }
}

/// Ask macOS to make an app frontmost. A helper launched from a terminal cannot
/// always activate another app through AppKit, so ask through Accessibility too.
func activate(_ pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    NSRunningApplication(processIdentifier: pid)?.activate()
}

func waitForFront(_ pid: pid_t, seconds: Double) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while frontmostPID() != pid, Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    else { return nil }
    return value
}

// MARK: - Target

enum Target {
    case window(Window)
    case display(CGDirectDisplayID, CGRect)

    var frame: CGRect {
        switch self {
        case .window(let window): return window.frame
        case .display(_, let frame): return frame
        }
    }

    var label: String {
        switch self {
        case .window: return "window"
        case .display: return "display"
        }
    }

    var isDisplay: Bool {
        if case .display = self { return true }
        return false
    }

    func point(_ x: String, _ y: String) throws -> CGPoint {
        guard let x = Int(x), let y = Int(y), x >= 0, y >= 0,
              CGFloat(x) < frame.width, CGFloat(y) < frame.height
        else {
            throw ControlError(
                "Coordinates are outside the selected \(label) (\(Int(frame.width)) × \(Int(frame.height)) points)."
            )
        }
        return CGPoint(x: frame.minX + CGFloat(x), y: frame.minY + CGFloat(y))
    }

    /// Check that a pointer event at this point reaches the selected target.
    /// `guardApps` also refuses points over the app running Vibe in display mode;
    /// a drag checks that only at its ends, so its path may cross that app.
    func checkPointer(_ point: CGPoint, windows: [Window]? = nil, guardApps: Bool = true) throws {
        switch self {
        case .window(let window):
            let current = windows ?? Window.onScreen()
            guard try Window.selected(window.id, window.pid, in: current).frame == window.frame
            else { throw ControlError("The selected window moved. Take another screenshot.") }
            try window.checkPointer(point, in: current)
        case .display(let id, let frame):
            guard CGDisplayIsActive(id) != 0, CGDisplayBounds(id) == frame else {
                throw ControlError("The selected display changed. Take another screenshot.")
            }
            guard frame.contains(point) else {
                throw ControlError("Coordinates are outside the selected display.")
            }
            if guardApps { try checkNotProtected(point, windows: windows ?? Window.onScreen()) }
        }
    }

    /// The window that will receive keyboard input, brought to the front.
    /// In display mode that is the app the model last clicked (`preferred`), or the
    /// frontmost app when there is none, but never the app running Vibe: after the
    /// user approves a call in Vibe, Vibe's terminal is usually frontmost.
    func keyboardWindow(preferred: pid_t) throws -> Window {
        switch self {
        case .window(let window):
            if frontmostPID() != window.pid { window.bringForward() }
            return window
        case .display(let id, let frame):
            if preferred > 0, frontmostPID() != preferred, !Protected.contains(preferred),
               NSRunningApplication(processIdentifier: preferred) != nil {
                activate(preferred)
                waitForFront(preferred, seconds: 1.5)
            }
            let front = frontmostPID()
            guard front != 0, !Protected.contains(front) else {
                throw ControlError(
                    "The app running Vibe has keyboard focus. Click the target window or text field first."
                )
            }
            guard CGDisplayIsActive(id) != 0, CGDisplayBounds(id) == frame,
                  let window = Window.onScreen().first(where: { $0.pid == front && $0.layer == 0 }),
                  frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
            else { throw ControlError("Click a text field in a window on the selected display first.") }
            return window
        }
    }

    /// A crop of the target, in its points, trimmed to its edges. Nil means all of it.
    func region(_ args: ArraySlice<String>) throws -> CGRect? {
        guard !args.isEmpty else { return nil }
        let values = args.compactMap { Int($0) }
        guard values.count == 4, args.count == 4, values[2] > 0, values[3] > 0
        else { throw ControlError("A screenshot region is x, y, width and height in whole points.") }
        let bounds = CGRect(x: 0, y: 0, width: frame.width.rounded(.up), height: frame.height.rounded(.up))
        let crop = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).intersection(bounds)
        guard !crop.isNull, crop.width >= 16, crop.height >= 16 else {
            throw ControlError(
                "The region must overlap the selected \(label) (\(Int(bounds.width)) × \(Int(bounds.height)) points) "
                    + "by at least 16 × 16 points."
            )
        }
        return crop
    }

    /// Writes a JSON line, then the image. The line has the target's size in points,
    /// the image format and, for a crop, the region captured and how many pixels
    /// show each point. Every image is a quality-70 JPEG: Vibe resends each one with
    /// every later model request, so their size decides how slow the session gets.
    func screenshot(region: CGRect?) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ControlError("Grant Screen Recording to the app running Vibe in System Settings.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        switch self {
        case .window(let window):
            guard let source = content.windows.first(where: {
                $0.windowID == window.id && $0.owningApplication?.processID == window.pid
            }) else { throw ControlError("The selected window is no longer available for capture.") }
            filter = SCContentFilter(desktopIndependentWindow: source)
        case .display(let id, _):
            guard let source = content.displays.first(where: { $0.displayID == id })
            else { throw ControlError("The selected display is no longer available for capture.") }
            filter = SCContentFilter(display: source, excludingWindows: [])
        }

        let width = Int(frame.width.rounded(.up))
        let height = Int(frame.height.rounded(.up))
        guard width * height <= 16_000_000 else {
            throw ControlError("Reduce the selected \(label)'s size below 16 million points squared.")
        }
        let configuration = SCStreamConfiguration()
        var metadata = "{\"size\": [\(width), \(height)]"
        if let region {
            // Enlarge a small crop so its targets are legible; on a Retina display the
            // extra pixels are real detail, not interpolation. A larger crop is
            // already legible, and enlarging it would only make the request heavier,
            // so no crop is more than 1,000 pixels on its long side because of zoom.
            let zoom = max(region.width, region.height) <= 500 ? 2 : 1
            configuration.sourceRect = region
            configuration.width = Int(region.width) * zoom
            configuration.height = Int(region.height) * zoom
            metadata += ", \"region\": [\(Int(region.minX)), \(Int(region.minY)), "
                + "\(Int(region.width)), \(Int(region.height))], \"zoom\": \(zoom)"
        } else {
            configuration.width = width
            configuration.height = height
        }
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        switch self {
        case .window(let window):
            guard try Window.selected(window.id, window.pid, in: Window.onScreen()).frame.size == frame.size
            else { throw ControlError("The window resized during capture. Take another screenshot.") }
        case .display(let id, let frame):
            guard CGDisplayIsActive(id) != 0, CGDisplayBounds(id) == frame
            else { throw ControlError("The selected display changed during capture. Take another screenshot.") }
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ControlError("Could not create the image encoder.") }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw ControlError("Could not encode the screenshot.")
        }
        metadata += ", \"format\": \"jpeg\""
        FileHandle.standardOutput.write(Data((metadata + "}\n").utf8))
        FileHandle.standardOutput.write(encoded as Data)
    }
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

struct KeyCombo {
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

func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    else { throw ControlError("Could not create a keyboard event.") }
    event.flags = flags
    return event
}

// MARK: - Mouse

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

func mouseEvent(
    _ type: CGEventType, _ point: CGPoint, _ button: Button = .left,
    clickState: Int64 = 1, flags: CGEventFlags = []
) throws -> CGEvent {
    guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button.cg
    ) else { throw ControlError("Could not create a mouse event.") }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.flags = flags
    return event
}

func click(_ point: CGPoint, button: Button, count: Int) throws {
    try mouseEvent(.mouseMoved, point, clickState: 0).post(tap: .cghidEventTap)
    usleep(20_000)
    for state in 1...count {
        let down = try mouseEvent(button.down, point, button, clickState: Int64(state))
        let up = try mouseEvent(button.up, point, button, clickState: Int64(state))
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func scroll(_ point: CGPoint, notches: Int32) throws {
    try mouseEvent(.mouseMoved, point, clickState: 0).post(tap: .cghidEventTap)
    usleep(40_000)
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: notches, wheel2: 0, wheel3: 0
    ) else { throw ControlError("Could not create a scroll event.") }
    event.location = point
    event.flags = []
    event.post(tap: .cghidEventTap)
    usleep(30_000)
}

func drag(
    _ start: CGPoint, _ end: CGPoint, button: Button, steps requested: Int, hold: [Modifier], in target: Target
) throws {
    guard start != end else { throw ControlError("Drag endpoints must differ.") }
    let distance = hypot(end.x - start.x, end.y - start.y)
    let steps = requested > 0 ? requested : max(12, Int(ceil(distance / 24)))
    let points = (1...steps).map { step in
        let fraction = CGFloat(step) / CGFloat(steps)
        return CGPoint(x: start.x + (end.x - start.x) * fraction,
                       y: start.y + (end.y - start.y) * fraction)
    }
    let initialWindows: [Window]? = if case .window = target { Window.onScreen() } else { nil }
    let deadline = DispatchTime.now() + .seconds(15)
    try target.checkPointer(start, windows: initialWindows)
    try target.checkPointer(end, windows: initialWindows)
    for point in points.dropLast() {
        guard DispatchTime.now() < deadline else { throw ControlError("The drag path check timed out.") }
        try target.checkPointer(point, windows: initialWindows, guardApps: false)
    }

    // Held modifiers are pressed as keys and set on every mouse event, as the
    // window server does for a person holding them. They are released last.
    var flags = CGEventFlags()
    var pressed: [Modifier] = []
    defer {
        for modifier in pressed.reversed() {
            flags.remove(modifier.flag)
            (try? keyEvent(modifier.keyCode, down: false, flags: flags))?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }
    for modifier in hold {
        flags.insert(modifier.flag)
        try keyEvent(modifier.keyCode, down: true, flags: flags).post(tap: .cghidEventTap)
        pressed.append(modifier)
        usleep(20_000)
    }

    let up = try mouseEvent(button.up, start, button, flags: flags)
    try mouseEvent(.mouseMoved, start, clickState: 0, flags: flags).post(tap: .cghidEventTap)
    usleep(20_000)
    try mouseEvent(button.down, start, button, flags: flags).post(tap: .cghidEventTap)
    defer {
        usleep(50_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    usleep(50_000)

    for point in points {
        guard DispatchTime.now() < deadline else { throw ControlError("The drag timed out.") }
        usleep(18_000)
        try target.checkPointer(point, guardApps: false)
        try mouseEvent(button.dragged, point, button, flags: flags).post(tap: .cghidEventTap)
        up.location = point
    }
}

/// Print the frontmost app after a click or drag, unless it is the app running
/// Vibe: the server sends later keyboard input there.
func reportFrontmost() {
    usleep(150_000)
    let pid = frontmostPID()
    print("{\"frontmost\": \(Protected.contains(pid) ? 0 : pid)}")
}

// MARK: - Keyboard

func waitForFocus(_ window: Window) throws {
    let deadline = DispatchTime.now() + .seconds(5)
    while true {
        do {
            try window.checkFocus()
            return
        } catch {
            guard DispatchTime.now() < deadline else { throw error }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }
}

func typeText(_ text: String, in window: Window) throws {
    try waitForFocus(window)
    for (index, character) in text.enumerated() {
        if index.isMultiple(of: 32) { try window.checkFocus() }
        guard frontmostPID() == window.pid else { throw ControlError("Focus changed while typing.") }
        if character == "\r" { continue }
        if character == "\n" || character == "\r\n" || character == "\t" {
            let code: CGKeyCode = character == "\t" ? 48 : 36
            try keyEvent(code, down: true).postToPid(window.pid)
            try keyEvent(code, down: false).postToPid(window.pid)
        } else {
            let units = Array(String(character).utf16)
            let down = try keyEvent(0, down: true)
            let up = try keyEvent(0, down: false)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.postToPid(window.pid)
            up.postToPid(window.pid)
        }
        usleep(8_000)
    }
}

/// In display mode the keys go through the system, so shortcuts such as cmd+tab
/// work; in window mode they go only to the selected window's app.
func pressKeys(_ combo: KeyCombo, in window: Window, systemWide: Bool) throws {
    try waitForFocus(window)
    let down = try keyEvent(combo.code, down: true, flags: combo.flags)
    let up = try keyEvent(combo.code, down: false, flags: combo.flags)
    guard frontmostPID() == window.pid else { throw ControlError("Focus changed before the keys were pressed.") }
    if systemWide {
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    } else {
        down.postToPid(window.pid)
        usleep(20_000)
        up.postToPid(window.pid)
    }
    usleep(30_000)
}

func readText() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty, text.utf16.count <= 2_000
    else { throw ControlError("Provide valid text of at most 2,000 UTF-16 units.") }
    guard text.allSatisfy({ String($0).utf16.count <= 20 }) else {
        throw ControlError("A text character is too long to send as a keyboard event.")
    }
    return text
}

// MARK: - Listing

func listDisplays() throws {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else {
        throw ControlError("Could not list active displays.")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        throw ControlError("Could not list active displays.")
    }
    for id in ids.prefix(Int(count)) {
        let frame = CGDisplayBounds(id)
        let main = id == CGMainDisplayID() ? " (main)" : ""
        print("\(id)\t\(Int(frame.width)) × \(Int(frame.height)) points\(main)")
    }
}

// MARK: - Entry point

enum Action {
    case click(CGPoint, Button, Int)
    case scroll(CGPoint, Int32)
    case drag(CGPoint, CGPoint, Button, Int, [Modifier])
    case type(String, pid_t)
    case keys(KeyCombo, pid_t)

    /// Validate every argument before any event is posted.
    static func parse(_ args: ArraySlice<String>, for target: Target) throws -> Action {
        let args = Array(args)
        switch (args.first, args.count) {
        case ("click", 5):
            guard let count = Int(args[4]), count == 1 || count == 2
            else { throw ControlError("The click count is 1 or 2.") }
            return .click(try target.point(args[1], args[2]), try Button.parse(args[3]), count)
        case ("scroll", 4):
            guard let notches = Int32(args[3]), notches != 0, abs(notches) <= 50
            else { throw ControlError("notches is a non-zero whole number from -50 to 50.") }
            return .scroll(try target.point(args[1], args[2]), notches)
        case ("drag", 8):
            guard let steps = Int(args[6]), (0...60).contains(steps)
            else { throw ControlError("steps is a whole number from 1 to 60.") }
            return .drag(
                try target.point(args[1], args[2]), try target.point(args[3], args[4]),
                try Button.parse(args[5]), steps, try Modifier.parseHold(args[7])
            )
        case ("type", 2):
            guard let pid = pid_t(args[1]) else { throw ControlError("Provide a numeric process ID.") }
            return .type(try readText(), pid)
        case ("keys", 3):
            guard let pid = pid_t(args[2]) else { throw ControlError("Provide a numeric process ID.") }
            return .keys(try KeyCombo.parse(args[1]), pid)
        default:
            throw ControlError("Invalid action or argument count.")
        }
    }
}

@main
struct WindowControl {
    @MainActor
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["windows"] {
                for window in Window.onScreen() where window.layer == 0 && !window.owner.isEmpty {
                    print("\(window.id)\t\(window.pid)\t\(window.owner)\t\(window.title)")
                }
                return
            }
            if args == ["displays"] {
                try listDisplays()
                return
            }
            if args == ["protected"] {
                for app in NSWorkspace.shared.runningApplications where Protected.contains(app.processIdentifier) {
                    print("\(app.processIdentifier)\t\(app.localizedName ?? "")")
                }
                return
            }
            guard args.count >= 3 else {
                throw ControlError("Usage: window-control windows, displays, WINDOW PID ACTION, or display ID ACTION")
            }
            let target: Target
            if args[0] == "display" {
                let id = args[1] == "main" ? CGMainDisplayID() : CGDirectDisplayID(args[1])
                guard let id, CGDisplayIsActive(id) != 0 else {
                    throw ControlError("The selected display is unavailable. Run window-control displays.")
                }
                target = .display(id, CGDisplayBounds(id))
            } else {
                guard let id = CGWindowID(args[0]), let pid = pid_t(args[1]) else {
                    throw ControlError("Provide a numeric window ID and process ID.")
                }
                target = .window(try Window.selected(id, pid, in: Window.onScreen()))
            }
            if args[2] == "screenshot" {
                try await target.screenshot(region: target.region(args[3...]))
                return
            }

            let action = try Action.parse(args[2...], for: target)
            guard AXIsProcessTrusted() && CGPreflightPostEventAccess() else {
                throw ControlError("Grant Accessibility to the app running Vibe in System Settings.")
            }
            if case .window(let window) = target, Protected.contains(window.pid) {
                throw ControlError("The selected window belongs to the app running Vibe. Select another window.")
            }

            switch action {
            case .click(let point, let button, let count):
                try target.checkPointer(point)
                try click(point, button: button, count: count)
                reportFrontmost()
            case .scroll(let point, let notches):
                try target.checkPointer(point)
                try scroll(point, notches: notches)
            case .drag(let start, let end, let button, let steps, let hold):
                try drag(start, end, button: button, steps: steps, hold: hold, in: target)
                reportFrontmost()
            case .type(let text, let preferred):
                try typeText(text, in: target.keyboardWindow(preferred: preferred))
            case .keys(let combo, let preferred):
                try pressKeys(combo, in: target.keyboardWindow(preferred: preferred), systemWide: target.isDisplay)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
