import AppKit
import ApplicationServices

/// Lets the picture-in-picture window be dragged anywhere with a plain drag.
///
/// The window belongs to the system, which snaps it to a corner unless the
/// Command key is held. There is no setting for that, so this adds the key:
/// a tap on the session's mouse events marks a drag that starts on the
/// picture-in-picture window as a Command-drag. Such a tap is only allowed
/// with Accessibility access, which the user grants once in System Settings.
///
/// The same access lets Drift put the window back where it was last left:
/// the frame is noted at the end of each drag or resize, and set again, over
/// Accessibility, when a video next goes into picture in picture.
@MainActor
final class PiPDrag {

    static let shared = PiPDrag()
    private static let key = "drift.pipDragAnywhere.v1"

    /// Whether the user has asked for this. Off until they do, since it
    /// involves granting the app a broad permission.
    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt, if access is not yet granted.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var running = false

    /// Starts if wanted and allowed; harmless to call again.
    func startIfWanted() {
        guard Self.wanted, Self.hasAccess, !running else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in PiPDrag.handle(type, event) },
            userInfo: nil
        ) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        running = false
    }

    // The tap's callback runs on the main run loop, where these live.
    nonisolated(unsafe) private static var dragging = false
    /// The press was on the window or just off its edge, where resizing
    /// starts: either way, where the window ends up is worth noting.
    nonisolated(unsafe) private static var shaping = false
    /// Command was already down when the press came, held by the user.
    nonisolated(unsafe) private static var userHoldsCommand = false
    /// Drift is holding Command down for the drag under way.
    nonisolated(unsafe) private static var holdingCommand = false
    /// Drift's Command is still down, let go of in a moment.
    nonisolated(unsafe) private static var releasing = false

    private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a slow tap off; switch it back on.
            MainActor.assumeIsolated { if let tap = shared.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            letGoOfCommand(after: 0)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            letGoOfCommand(after: 0)
            dragging = isOverPictureInPicture(event.location)
            shaping = isOverPictureInPicture(event.location, margin: 8)
            userHoldsCommand = event.flags.contains(.maskCommand) && !releasing
        case .leftMouseDragged:
            // Marking the events is not always enough: where the window lands
            // is settled from the keyboard's own state once the drag ends, as
            // with the move in `move(_:to:)`, so the key is held for real,
            // from the first move until just after the button comes up.
            if dragging, !userHoldsCommand, !holdingCommand {
                holdingCommand = true
                postCommand(down: true)
            }
        default:
            break
        }
        if dragging { event.flags.insert(.maskCommand) }
        if type == .leftMouseUp {
            dragging = false
            letGoOfCommand(after: 0.3)
            if shaping {
                shaping = false
                // Once the window has settled under the pointer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated { shared.rememberPlace() }
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private static func letGoOfCommand(after delay: TimeInterval) {
        guard holdingCommand else { return }
        holdingCommand = false
        guard delay > 0 else { postCommand(down: false); return }
        releasing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            releasing = false
            // Unless another drag has taken the key up again meanwhile.
            if !holdingCommand { postCommand(down: false) }
        }
    }

    private static func postCommand(down: Bool) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0x37, keyDown: down)
        event?.flags = down ? .maskCommand : []
        event?.post(tap: .cghidEventTap)
    }

    /// Whether the point is on the system's picture-in-picture window, or
    /// within `margin` of it.
    static func isOverPictureInPicture(_ point: CGPoint, margin: CGFloat = 0) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return pictureInPictureWindows(in: windows).contains { $0.frame.insetBy(dx: -margin, dy: -margin).contains(point) }
    }

    /// The system's picture-in-picture windows among those listed. They are
    /// its PIPAgent's, told by the process and not by the owner's name: that
    /// is the agent's display name, "Picture in Picture", in the user's
    /// language, and not "PIPAgent".
    nonisolated static func pictureInPictureWindows(in windows: [[String: Any]], isAgent: (pid_t) -> Bool = isAgent) -> [(owner: pid_t, frame: CGRect)] {
        var agents: [pid_t: Bool] = [:]
        return windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let agent = agents[owner] ?? isAgent(owner)
            agents[owner] = agent
            guard agent else { return nil }
            return (owner, CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0))
        }
    }

    /// Whether the process runs the system's picture-in-picture agent. Asked
    /// afresh each time, since a process number is handed on once the agent,
    /// which quits when no video is out, has gone.
    nonisolated static func isAgent(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path).hasSuffix("/PIPAgent.app/Contents/MacOS/PIPAgent")
    }

    // MARK: - Where it was left

    private static let placeKey = "drift.pipPlace.v1"

    /// The last place the user left the window, in the system's screen
    /// coordinates: top left of the main display, y downwards.
    private var place: CGRect? {
        get {
            guard let values = UserDefaults.standard.array(forKey: Self.placeKey) as? [Double], values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        set {
            guard let newValue else { UserDefaults.standard.removeObject(forKey: Self.placeKey); return }
            UserDefaults.standard.set([newValue.minX, newValue.minY, newValue.width, newValue.height], forKey: Self.placeKey)
        }
    }

    private func rememberPlace() {
        guard running, let window = Self.pictureInPictureWindow(), let frame = Self.frame(of: window) else { return }
        place = frame
    }

    /// A video has just gone into picture in picture: once the system's
    /// window is up and done animating in, it goes where it was last left.
    func restorePlace() {
        guard running, let place, Self.isOnSomeScreen(place) else { return }
        waitForWindow(attempts: 20) { window in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { Self.move(window, to: place) }
            }
        }
    }

    private func waitForWindow(attempts: Int, then body: @escaping (AXUIElement) -> Void) {
        if let window = Self.pictureInPictureWindow() { body(window); return }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { self.waitForWindow(attempts: attempts - 1, then: body) }
        }
    }

    /// The size takes as it is, give or take the video's shape. The position
    /// is pulled back to a corner unless Command is down, as with a drag, so
    /// Command is held for the moment it takes.
    private static func move(_ window: AXUIElement, to place: CGRect) {
        var size = place.size
        var origin = place.origin
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        let source = CGEventSource(stateID: .hidSystemState)
        let command: CGKeyCode = 0x37
        let down = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let up = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
                up?.flags = []
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func pictureInPictureWindow() -> AXUIElement? {
        // The agent is found through its window, as for a drag.
        guard let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let agent = pictureInPictureWindows(in: listed).first?.owner else { return nil }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(agent), kAXWindowsAttribute as CFString, &windows) == .success else { return nil }
        return (windows as? [AXUIElement])?.first
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// A place left on a display that has since gone is not put back.
    private static func isOnSomeScreen(_ place: CGRect) -> Bool {
        guard let height = NSScreen.screens.first?.frame.height else { return false }
        let center = CGPoint(x: place.midX, y: height - place.midY)
        return NSScreen.screens.contains { $0.visibleFrame.contains(center) }
    }
}
