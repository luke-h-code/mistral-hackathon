// The computer-use helper: captures the selected display or window and posts mouse
// and keyboard input to it. Pure decisions live in Logic.swift. Build both:
//   swiftc -parse-as-library Logic.swift WindowControl.swift -o window-control

import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

func frontmostApp() -> NSRunningApplication? {
    NSWorkspace.shared.frontmostApplication
}

func frontmostPID() -> pid_t {
    frontmostApp()?.processIdentifier ?? 0
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

    /// In window mode, pointer input must land on the selected window.
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

    /// Check that a pointer event at this point reaches the selected target. In
    /// display mode any point on the display is allowed, whichever app is there.
    func checkPointer(_ point: CGPoint, windows: [Window]? = nil) throws {
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
        }
    }

    /// Prepare for keyboard input and return the name of the app that will get it.
    /// The selected window, or in display mode the app last clicked (`preferred`),
    /// is brought back to the front. Input then goes to whatever has focus there,
    /// popups and dialogs included.
    func prepareKeyboard(preferred: pid_t) -> String {
        let wanted: pid_t
        if case .window(let window) = self { wanted = window.pid } else { wanted = preferred }
        let decision = keyboardTarget(
            frontmost: frontmostPID(), preferred: wanted,
            preferredRunning: NSRunningApplication(processIdentifier: wanted) != nil
        )
        if case .activate(let pid) = decision {
            if case .window(let window) = self { window.bringForward() } else { activate(pid) }
            waitForFront(pid, seconds: 1.5)
        }
        return frontmostApp()?.localizedName ?? "the focused app"
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
            let zoom = cropZoom(region)
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

// MARK: - Events

func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    else { throw ControlError("Could not create a keyboard event.") }
    event.flags = flags
    return event
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

/// In window mode every point of the path must be over the selected window; in
/// display mode it only has to stay on the display.
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
    for point in [start] + points {
        guard DispatchTime.now() < deadline else { throw ControlError("The drag path check timed out.") }
        try target.checkPointer(point, windows: initialWindows)
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
        try target.checkPointer(point)
        try mouseEvent(button.dragged, point, button, flags: flags).post(tap: .cghidEventTap)
        up.location = point
    }
}

/// Print the frontmost app after a click or drag; the server sends later keyboard
/// input there.
func reportFrontmost() {
    usleep(150_000)
    print("{\"frontmost\": \(frontmostPID())}")
}

/// Print which app received keyboard input, so the model can tell where it went.
func reportKeyboard(_ app: String) {
    let name = (try? JSONSerialization.data(withJSONObject: ["app": app]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    print(name)
}

// MARK: - Keyboard

/// Typing goes through the system, like a real keyboard, so it reaches whatever
/// has focus: a text field, a popup, a dialog or system UI.
func typeText(_ text: String) throws {
    for key in typedKeys(text) {
        switch key {
        case .key(let code):
            try keyEvent(code, down: true).post(tap: .cghidEventTap)
            try keyEvent(code, down: false).post(tap: .cghidEventTap)
        case .unicode(let units):
            let down = try keyEvent(0, down: true)
            let up = try keyEvent(0, down: false)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        usleep(8_000)
    }
}

/// Keys go through the system too, so shortcuts such as cmd+tab work.
func pressKeys(_ combo: KeyCombo) throws {
    try keyEvent(combo.code, down: true, flags: combo.flags).post(tap: .cghidEventTap)
    usleep(20_000)
    try keyEvent(combo.code, down: false, flags: combo.flags).post(tap: .cghidEventTap)
    usleep(30_000)
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
            return .type(try validateText(FileHandle.standardInput.readDataToEndOfFile()), pid)
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
                let region = try cropRegion(Array(args[3...]), within: target.frame.size, label: target.label)
                try await target.screenshot(region: region)
                return
            }

            let action = try Action.parse(args[2...], for: target)
            guard AXIsProcessTrusted() && CGPreflightPostEventAccess() else {
                throw ControlError("Grant Accessibility to the app running Vibe in System Settings.")
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
                let app = target.prepareKeyboard(preferred: preferred)
                try typeText(text)
                reportKeyboard(app)
            case .keys(let combo, let preferred):
                let app = target.prepareKeyboard(preferred: preferred)
                try pressKeys(combo)
                reportKeyboard(app)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
