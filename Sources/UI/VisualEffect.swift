import AppKit
import SwiftUI

/// Frosted glass from AppKit. SwiftUI's own materials only blur what is inside
/// the window; the sidebar wants what is *behind* the window, the desktop and
/// whatever else is back there, which is this.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// When set, only the four corners outside a rounded rectangle of this
    /// radius are drawn. Laid over a square-cornered page it rounds the page
    /// off in the same glass as the frame round it, which a flat colour could
    /// not match.
    var cornersOnly: CGFloat?
    /// When set, the glass itself is a rounded rectangle of this radius: a
    /// panel floating on whatever is behind it.
    var rounded: CGFloat?

    final class Glass: NSVisualEffectView {
        var passesClicks = false
        override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }
    }

    func makeNSView(context: Context) -> Glass {
        let view = Glass()
        // Stays glass when the window is in the background, rather than going
        // flat grey the way a stock sidebar does.
        view.state = .active
        return view
    }

    func updateNSView(_ view: Glass, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.passesClicks = cornersOnly != nil
        if let cornersOnly {
            view.maskImage = Self.mask(radius: cornersOnly, corners: true)
        } else if let rounded {
            view.maskImage = Self.mask(radius: rounded, corners: false)
        } else {
            view.maskImage = nil
        }
    }

    /// A stretchable mask: either the rounded rectangle, or everything but it.
    /// The cap insets keep the corners their size while the middle grows.
    private static func mask(radius: CGFloat, corners: Bool) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let path: NSBezierPath
            if corners {
                path = NSBezierPath(rect: rect)
                path.append(shape)
                path.windingRule = .evenOdd
            } else {
                path = shape
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Moves the close, minimise and zoom buttons in from the window's corner, so
/// they sit inside the floating sidebar rather than straddling its edge. AppKit
/// puts them back whenever it lays the title bar out, so this puts them back
/// again after every resize.
struct WindowButtons: NSViewRepresentable {
    static let left: CGFloat = 20
    static let top: CGFloat = 14

    let store: BrowserStore

    /// Also where a store learns which window it is in, which the key monitor
    /// and the menu bar need once there is more than one.
    final class Probe: NSView {
        private var watching: [NSObjectProtocol] = []
        weak var store: BrowserStore?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            guard let window, let store else { return }
            store.window = window
            if window.isKeyWindow { WindowRouter.shared.active = store }
            watching.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak store] _ in
                MainActor.assumeIsolated { if let store { WindowRouter.shared.active = store } }
            })
            // Every browser window may take a Space of its own in full screen.
            // Without this a second window opened over a full-screen one only
            // swells to fill that Space, on top of the first.
            window.collectionBehavior.insert(.fullScreenPrimary)
            if store.isPrivateWindow {
                // Closing the private window is what ends the private session.
                watching.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { PrivateSession.shared.end() }
                })
                // Opened from a full-screen window, it goes full screen too,
                // in its own Space, rather than sitting over the first.
                if BrowserStore.shared.window?.styleMask.contains(.fullScreen) == true, !window.styleMask.contains(.fullScreen) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
                        guard let window, !window.styleMask.contains(.fullScreen) else { return }
                        window.toggleFullScreen(nil)
                    }
                }
            }
            // Told at the start of each transition, so the frame goes and
            // comes back as part of the animation rather than after it.
            let screen: [(Notification.Name, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true),
                (NSWindow.willExitFullScreenNotification, false),
            ]
            watching += screen.map { name, full in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        store.isFullScreen = full
                        store.fullScreenTransition = true
                        if !full { store.windowLeavingFullScreen() }
                    }
                }
            }
            let settled: [Notification.Name] = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
            watching += settled.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { store.fullScreenTransition = false }
                }
            }
            // Covered, minimised, or on a Space the user left: a playing video
            // follows them out in picture in picture. See
            // BrowserStore.applicationActiveChanged.
            watching.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { store.windowSightChanged() }
                }
            )
            store.isFullScreen = window.styleMask.contains(.fullScreen)
            let moments: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            ]
            watching += moments.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                }
            }
            // When the window finishes leaving macOS full screen, a page that
            // left full screen with it takes keyboard focus back (see
            // BrowserStore.windowDidExitFullScreen).
            watching.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { store.windowDidExitFullScreen() }
                }
            )
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        func place() {
            // In full screen the buttons live in the menu bar's pull-down.
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, kind) in kinds.enumerated() {
                guard let button = window.standardWindowButton(kind), let holder = button.superview else { continue }
                // Never below the title bar's own bounds, or they get clipped.
                let y = max(0, holder.bounds.height - button.frame.height - WindowButtons.top)
                button.setFrameOrigin(NSPoint(x: WindowButtons.left + CGFloat(index) * 20, y: y))
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.store = store
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) { view.place() }
}
