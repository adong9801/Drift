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

        // Escape the page did not want climbs the responder chain to the
        // window, where AppKit takes it as "leave full screen". Stopped here,
        // just above the page: full screen is the window's to keep.
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { return }
            super.keyDown(with: event)
        }

        override func cancelOperation(_ sender: Any?) {}

        func show(_ webView: WKWebView) {
            guard hosted !== webView || webView.superview !== self else { return }
            // A video gone full screen has been lifted out of here by WebKit,
            // into a window of its own, with a stand-in left behind. It comes
            // back by itself. Taking it back early, as any redraw of the window
            // would, pulls the page out from under the full-screen transition.
            guard hosted !== webView || webView.fullscreenState == .notInFullscreen else { return }
            hosted = webView
            // A cut, not a fade: the page is there the moment it is chosen. A
            // page just woken has nothing painted yet and shows the window's
            // own colour (see `underPageBackgroundColor` in `Tab.materialize`)
            // while it loads.
            for view in subviews where view !== webView { view.removeFromSuperview() }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            webView.alphaValue = 1
            if webView.superview !== self { addSubview(webView) }
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
