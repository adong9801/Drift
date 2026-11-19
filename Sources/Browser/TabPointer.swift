import AppKit
import WebKit

/// The pointer's side of a tab: whether its moves reach the page, and, when
/// they seem not to, what might be stopping them. See `PointerWatch`.
extension Tab {

    /// A move Drift saw over this page, at a point in its window.
    func pointerMoved(at point: NSPoint) {
        // Out of sight the page is meant not to hear: see `HoverGate`.
        guard (webView as? PageView)?.isInSight ?? false else { return }
        let report = pointer.driftSawMove()
        if pointer.shouldNudge() { askToDraw() }
        guard report, let webView else { return }
        var text = "Drift saw the pointer moving over the page for \(Int(PointerWatch.moving))s, and the page heard none of it"
        // WebKit stops passing moves on while it takes a page into its own full
        // screen, and starts again once it is there. Stuck, the page never
        // hears the pointer again.
        if webView.fullscreenState == .notInFullscreen, Self.flag(webView, "_ignoresMouseMoveEvents") == true {
            Self.setFlag(webView, "_setIgnoresMouseMoveEvents:", false)
            text += ". WebKit had stopped passing moves on outside full screen; started it again"
        }
        note("mouse", text + ". " + pointerReport(at: point))
    }

    /// Everything that decides where a pointer move over this page goes, and
    /// what the cursor is. For the log above and the debugging archive.
    func pointerReport(at point: NSPoint?) -> String {
        guard let webView else { return "asleep" }
        let window = webView.window
        var parts: [String] = []
        parts.append("window: \(window.map { $0 === store?.window ? "its own" : String(describing: type(of: $0)) } ?? "none")")
        parts.append("key window: \(NSApp.keyWindow.map { $0 === window ? "the same" : String(describing: type(of: $0)) } ?? "none"), app active: \(NSApp.isActive)")
        parts.append("first responder: \(window?.firstResponder.map { $0 === webView ? "the page" : String(describing: type(of: $0)) } ?? "none")")
        let on = ["_ignoresMouseMoveEvents", "_ignoresNonWheelEvents", "_ignoresAllEvents"].filter { Self.flag(webView, $0) == true }
        parts.append("WebKit ignoring: \(on.isEmpty ? "nothing" : on.joined(separator: ", "))")
        parts.append("WebKit full screen: \(Self.describe(webView.fullscreenState)), Drift's: \(isPageFullscreen), hidden: \(webView.isHiddenOrHasHiddenAncestor)")
        if let page = webView as? PageView {
            parts.append("page draws: \(page.isInSight ? "yes" : "no, macOS has its window out of sight"), occlusion: \(window.map { $0.occlusionState.contains(.visible) ? "visible" : "covered" } ?? "no window")")
        }
        parts.append("tracking: \(Self.trackingSummary(webView))")
        if let window, let point, let content = window.contentView {
            let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            let what = hit.map { $0 === webView || $0.isDescendant(of: webView) ? "the page" : String(describing: type(of: $0)) }
            parts.append("under the pointer: \(what ?? "nothing")")
        }
        parts.append("cursor: \(Self.describe(NSCursor.current)), on screen: \(NSCursor.currentSystem.map(Self.describe) ?? "unknown")")
        let heard = pointer.pageHeard == .distantPast ? "never" : String(format: "%.1fs ago", Date().timeIntervalSince(pointer.pageHeard))
        parts.append("page last heard the pointer: \(heard)")
        return parts.joined(separator: "; ")
    }

    fileprivate func pageHeardPointer() { pointer.pageHeardMove() }

    /// Makes the page draw, which is what lets WebKit pass it the moves it
    /// has been holding back. The log says if it was slow, or never drew.
    func askToDraw() {
        guard let webView else { return }
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard webView.responds(to: selector), let implementation = webView.method(for: selector) else { return }
        let asked = Date()
        pointer.drawAsked = asked
        // WebKit keeps the block until the page has drawn, so it is marked
        // escaping. A block parameter of a C function type is otherwise
        // non-escaping, and Swift stops the app the moment it sees it kept.
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(implementation, to: Call.self)(webView, selector) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pointer.drawAsked == asked else { return }
                self.pointer.drawAsked = nil
                let took = Date().timeIntervalSince(asked)
                if took > 0.5 { self.note("mouse", String(format: "The page was asked to draw so it could hear the pointer, and took %.1fs", took)) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pointer.drawAsked == asked else { return }
            self.pointer.drawAsked = nil
            self.note("mouse", "The page was asked to draw so it could hear the pointer, and had not 3s later. " + self.pointerReport(at: nil))
        }
    }

    // MARK: - Describing

    private static func flag(_ view: WKWebView, _ name: String) -> Bool? {
        guard view.responds(to: NSSelectorFromString(name)) else { return nil }
        return view.value(forKey: name) as? Bool
    }

    private static func setFlag(_ view: WKWebView, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard view.responds(to: selector), let implementation = view.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Setter.self)(view, selector, value)
    }

    private static func describe(_ state: WKWebView.FullscreenState) -> String {
        switch state {
        case .notInFullscreen: return "no"
        case .enteringFullscreen: return "entering"
        case .inFullscreen: return "yes"
        case .exitingFullscreen: return "leaving"
        @unknown default: return "unknown"
        }
    }

    /// WebKit's own cursors are the system's for the common shapes, and a
    /// blank 1×1 image for a page's `cursor: none`.
    static func describe(_ cursor: NSCursor) -> String {
        if cursor === NSCursor.arrow { return "arrow" }
        if cursor === NSCursor.iBeam { return "I-beam" }
        if cursor === NSCursor.pointingHand { return "pointing hand" }
        let size = cursor.image.size
        if size.width <= 1, size.height <= 1 { return "blank (a page's cursor: none)" }
        return "other \(Int(size.width))×\(Int(size.height))"
    }

    /// The page's tracking areas, which are what turn the pointer's movement
    /// into events for it. One that tracks moves should be active always; see
    /// `PageView.updateTrackingAreas`.
    private static func trackingSummary(_ view: NSView) -> String {
        var moves: [String] = [], others = 0
        func walk(_ v: NSView) {
            for area in v.trackingAreas {
                if area.options.contains(.mouseMoved) {
                    moves.append(area.options.contains(.activeAlways) ? "always" : area.options.contains(.activeInKeyWindow) ? "key window only" : "other")
                } else {
                    others += 1
                }
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return "\(moves.count) for moves (\(moves.joined(separator: ", "))), \(others) other"
    }
}

/// The page's word that it heard the pointer move. See `PointerWatch.script`.
final class TabPointerBridge: NSObject, WKScriptMessageHandler {
    static let shared = TabPointerBridge()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            (message.webView as? PageView)?.tab?.pageHeardPointer()
        }
    }
}
