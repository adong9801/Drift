import SwiftUI
import WebKit

/// Puts a tab's web view on screen. The web view belongs to the tab and
/// outlives this wrapper; all this does is re-parent it, so switching tabs
/// never reloads anything.
///
/// There is deliberately no corner mask here. Clipping a web view to a rounded
/// rect makes the compositor redraw it through an offscreen pass on every
/// frame, which is felt as heavy scrolling. The rounded corners are painted
/// over the top instead; see `CornerCaps`.
struct WebPane: NSViewRepresentable {
    let tab: Tab

    final class Host: NSView {
        private weak var hosted: WKWebView?

        /// The pages shown here before this one, newest first. They stay in
        /// the window, hidden, rather than being taken out of it.
        ///
        /// A page put back into a window gets painted afresh, and WebKit holds
        /// the whole app until it has been, for up to a quarter of a second. A
        /// heavy page (ChatGPT, with a password manager looking it over as its
        /// tab comes forward) takes all of that and is still blank after it.
        /// A hidden page still has its last picture, and is back at once.
        ///
        /// To its scripts a hidden page is as gone as one taken out: hidden,
        /// with no animation frames and its timers slowed. What it keeps is
        /// that picture, so only the last few are kept; Ctrl-Tab mostly goes
        /// between them.
        static let warmLimit = 3
        private var shownBefore: [Weak] = []

        private struct Weak {
            weak var view: WKWebView?
        }

        // Escape the page did not want climbs the responder chain to the
        // window, where AppKit takes it as "leave full screen". Stopped here,
        // just above the page: full screen is the window's to keep.
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { return }
            super.keyDown(with: event)
        }

        override func cancelOperation(_ sender: Any?) {}

        func show(_ webView: WKWebView) {
            guard hosted !== webView || webView.superview !== self || webView.isHidden else { return }
            // A video gone full screen has been lifted out of here by WebKit,
            // into a window of its own, with a stand-in left behind. It comes
            // back by itself. Taking it back early, as any redraw of the window
            // would, pulls the page out from under the full-screen transition.
            guard hosted !== webView || webView.fullscreenState == .notInFullscreen else { return }
            let previous = hosted
            hosted = webView

            // Newest first, without the page now shown, and only pages still
            // here: one put to sleep or closed has already left.
            var kept = shownBefore.compactMap(\.view).filter { $0 !== webView && $0.superview === self }
            if let previous, previous !== webView, previous.superview === self { kept.insert(previous, at: 0) }
            kept = Array(kept.prefix(Self.warmLimit))
            shownBefore = kept.map { Weak(view: $0) }

            // A cut, not a fade: the page is there the moment it is chosen. A
            // page just woken has nothing painted yet and shows the window's
            // own colour (see `underPageBackgroundColor` in `Tab.materialize`)
            // while it loads. Older pages, and a full-screen stand-in, go.
            for view in subviews where view !== webView {
                if kept.contains(where: { $0 === view }) { view.isHidden = true } else { view.removeFromSuperview() }
            }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            webView.alphaValue = 1
            webView.isHidden = false
            if webView.superview !== self { addSubview(webView) }

            // The page shown goes on top of the hidden ones. A drag does not
            // look at whether a page is hidden: it goes to the topmost page
            // under the pointer, so a page woken after this one and still
            // above it, hidden, took the drop (an image dropped on ChatGPT
            // landed in a Google Doc in the tab before it). Sorting reorders
            // in place; taking the page out and adding it back would make
            // WebKit paint it afresh, which is what keeping pages here avoids.
            if subviews.last !== webView {
                sortSubviews({ a, b, shown in
                    let shown = shown.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
                    if a === shown { return .orderedDescending }
                    if b === shown { return .orderedAscending }
                    return .orderedSame
                }, context: Unmanaged.passUnretained(webView).toOpaque())
            }
        }
    }

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ host: Host, context: Context) {
        host.show(tab.materialize())
    }
}

/// The four corners of a rectangle with a rounded rectangle cut out of it.
/// Filled with the frame's colour and laid over a square-cornered page, it
/// gives the page round corners without masking it.
struct CornerCaps: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}
