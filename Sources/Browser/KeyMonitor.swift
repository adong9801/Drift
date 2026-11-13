import AppKit

/// The keys and clicks that cannot be menu items.
///
/// Ctrl-Tab is the reason this exists. It is not one shortcut but a gesture:
/// Tab steps while Control is held, and letting go of Control is the commit.
/// A menu item sees the first half and never the second, and the web view would
/// otherwise eat the Tab. A local monitor sees every event before either does.
@MainActor
final class KeyMonitor {

    private enum Key {
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
        static let w: UInt16 = 13
        static let q: UInt16 = 12
        static let up: UInt16 = 126
        static let down: UInt16 = 125
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    static let shared = KeyMonitor()

    private var monitor: Any?

    private init() {}

    /// One monitor for the whole app, however many windows there are. Each
    /// event goes to the store of the window it happened in.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .otherMouseDown, .mouseMoved, .systemDefined]
        ) { [weak self] event in
            // Not `self?.handle(event) ?? event`: a nil from `handle` means
            // "swallow this", and `??` would hand the event straight back.
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    /// Returns nil to swallow the event.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Flag changes carry no window; they belong to whichever is in front.
        guard let store = BrowserStore.store(for: event.window) ?? BrowserStore.store(for: NSApp.keyWindow) else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Off by default on a window, and without it no moves arrive at all.
        if let window = event.window, !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }

        switch event.type {
        case .mouseMoved:
            // Only moves within the browser window itself: a popover is a
            // window of its own, and its coordinates say nothing about the sidebar.
            if !store.sidebarVisible, event.window === store.window { store.pointerMoved(x: event.locationInWindow.x) }
            return event

        case .flagsChanged:
            if store.switcher != nil, !flags.contains(.control) { store.commitSwitcher() }
            if !flags.contains(.command) { QuitHold.shared.cancel() }
            return event

        case .keyUp:
            if event.keyCode == Key.q { QuitHold.shared.cancel() }
            return event

        case .systemDefined:
            // The media keys, as the system hands them to the app in front:
            // noted for the debugging archive, and left for the system to route.
            if event.subtype.rawValue == 8 {
                let code = (event.data1 & 0xFFFF0000) >> 16
                let down = ((event.data1 & 0x0000FF00) >> 8) == 0x0A
                let names = [16: "play/pause", 17: "next", 18: "previous", 19: "fast forward", 20: "rewind", 0: "brightness up", 2: "brightness down", 7: "mute", 1: "volume up", 3: "volume down"]
                if down { store.focused?.note("key", "media key \(names[code] ?? "\(code)") pressed with Drift in front") }
            }
            return event

        case .leftMouseDown:
            // With the overlay up the click is the overlay's: a card lands
            // there, the backdrop puts it away.
            if store.switcher == nil { focusPane(under: event, in: store) }
            Tab.noteClick(command: flags.contains(.command), button: 0)
            return event

        case .otherMouseDown:
            // A mouse's side buttons go back and forward. The middle button
            // is left to the page, where a link under it opens behind.
            store.focused?.note("key", "mouse button \(event.buttonNumber) pressed")
            if event.window === store.window, store.mouseButton(event.buttonNumber) { return nil }
            Tab.noteClick(command: false, button: event.buttonNumber)
            return event

        case .keyDown:
            // Quitting takes a held Command-Q, as in Arc and Chrome: a browser
            // full of tabs is too much to lose to a slip of the fingers.
            if event.keyCode == Key.q, flags == [.command] {
                QuitHold.shared.press(repeated: event.isARepeat)
                return nil
            }
            if event.keyCode == Key.tab, flags.contains(.control), !flags.contains(.command) {
                store.advanceSwitcher(backwards: flags.contains(.shift))
                return nil
            }
            if store.switcher != nil {
                // Control is down for the whole gesture, so closing the
                // highlighted tab is just W: it arrives as Ctrl-W. Adding
                // Command out of habit works too.
                if event.keyCode == Key.w {
                    store.closeSwitcherSelection()
                    return nil
                }
                switch event.keyCode {
                case Key.escape: store.cancelSwitcher()
                case Key.left: store.advanceSwitcher(backwards: true)
                case Key.right: store.advanceSwitcher(backwards: false)
                case Key.up: store.moveSwitcherRow(down: false)
                case Key.down: store.moveSwitcherRow(down: true)
                default: break
                }
                return nil
            }
            if let full = store.fullscreenTab, event.keyCode == Key.escape, store.commandBar == nil {
                full.exitPageFullscreen()
                return nil
            }
            if store.commandBar != nil {
                switch event.keyCode {
                case Key.escape:
                    store.dismissCommandBar()
                    return nil
                case Key.up:
                    store.onArrow?(false)
                    return nil
                case Key.down:
                    store.onArrow?(true)
                    return nil
                case Key.delete where flags.contains(.shift):
                    store.onForget?()
                    return nil
                default:
                    return event
                }
            }
            // A shortcut an extension has claimed, such as a password
            // manager's fill key.
            if store.commandBar == nil, Extensions.shared.performCommand(for: event) { return nil }
            if store.findVisible, event.keyCode == Key.escape {
                store.dismissFind()
                return nil
            }
            return event

        default:
            return event
        }
    }

    /// In split view, a click inside a pane makes it the focused one, so the
    /// address and the shortcuts follow where the user is working.
    private func focusPane(under event: NSEvent, in store: BrowserStore) {
        guard store.split != nil else { return }
        for (pane, tab) in [(Pane.primary, store.selected), (Pane.secondary, store.split)] {
            guard let view = tab?.webView, view.window === event.window else { continue }
            if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                if store.focusedPane != pane { store.focusedPane = pane }
                return
            }
        }
    }
}

/// Command-Q held for a moment quits; tapped, it only shows how.
@MainActor
final class QuitHold: ObservableObject {
    static let shared = QuitHold()
    static let duration: TimeInterval = 0.8

    /// Shown while the key is down, with how far along the hold is.
    @Published private(set) var holding = false
    private var began: Date?
    private var timer: Timer?

    func press(repeated: Bool) {
        if began == nil {
            began = Date()
            holding = true
            let timer = Timer(timeInterval: Self.duration, repeats: false) { _ in
                MainActor.assumeIsolated { QuitHold.shared.finish() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func cancel() {
        began = nil
        holding = false
        timer?.invalidate()
        timer = nil
    }

    private func finish() {
        guard began != nil else { return }
        cancel()
        NSApp.terminate(nil)
    }
}
