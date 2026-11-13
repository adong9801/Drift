import SwiftUI

extension PageTint {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    /// Text and icons that stay legible on it.
    var ink: Color { wantsLightText ? .white : Color(.sRGB, white: 0.1) }
}

/// The window's colour when the sidebar is hidden: the focused page's top
/// colour, so the bar reads as part of the page. Its own view so that it, and
/// not the whole window, redraws when a page reports a new colour.
struct FrameTint: View {
    let tab: Tab?

    var body: some View {
        if let tab { Observed(tab: tab) } else { Design.chrome }
    }

    private struct Observed: View {
        @ObservedObject var tab: Tab

        var body: some View {
            (tab.tint?.color ?? Design.chrome)
                .animation(.easeOut(duration: 0.3), value: tab.tint)
        }
    }
}

/// The page's round corners, in whatever the frame round it is made of: the
/// focused page's tint when `tab` is given, the sidebar's glass otherwise. Watches
/// the tab itself, so the corners change colour in step with `FrameTint`.
struct FrameCorners: View {
    let tab: Tab?

    var body: some View {
        // With the sidebar showing, the frame is glass, so the corners are cut
        // from the same glass.
        if let tab { Observed(tab: tab) } else { VisualEffect(material: .underWindowBackground, cornersOnly: Design.pageRadius) }
    }

    private struct Observed: View {
        @ObservedObject var tab: Tab

        var body: some View {
            caps(tab.tint?.color ?? Design.chrome)
                .animation(.easeOut(duration: 0.3), value: tab.tint)
        }
    }
}

private func caps(_ color: Color) -> some View {
    CornerCaps(radius: Design.pageRadius).fill(color, style: FillStyle(eoFill: true))
}

/// Navigation and the address, across the top, for when there is no sidebar to
/// hold them. Drawn in whichever of black or white reads on the page's colour.
struct TopBar: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore

    /// Tall enough that its controls centre on the window buttons, which
    /// `WindowButtons` has moved down and in.
    static let height: CGFloat = 40

    private var ink: Color { tab.tint?.ink ?? Design.text }

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                // Clear of the traffic lights.
                Color.clear.frame(width: store.isFullScreen ? 10 : 86, height: 1)
                Button { store.sidebarVisible = true } label: { icon("sidebar.left") }
                    .help("Show sidebar (\\u{2318}S)")
                Button { tab.goBack() } label: { icon("arrow.left") }.disabled(!tab.canGoBack)
                Button { tab.goForward() } label: { icon("arrow.right") }.disabled(!tab.canGoForward)
                Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                    icon(tab.isLoading ? "xmark" : "arrow.clockwise")
                }
                Spacer()
                if tab.hasVideo {
                    Button { tab.pictureInPicture(.toggle) } label: { icon("pip.enter") }
                        .help("Picture in picture (\u{2325}\u{2318}P)")
                }
                if store.isPrivateWindow {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.8))
                        .padding(.trailing, 12)
                } else {
                    ExtensionBar(ink: ink)
                        .padding(.trailing, 6)
                }
                if store.split != nil {
                    Image(systemName: store.focusedPane == .primary
                        ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.5))
                        .padding(.trailing, 12)
                }
            }
            .buttonStyle(.plain)

            address
        }
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.3), value: tab.tint)
    }

    /// Host in full strength, the rest of the address fainter after it. Click
    /// for the command bar, where the whole thing can be edited or copied.
    private var address: some View {
        Button { store.commandBar = .current } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.isPrivate ? "eye.slash" : (tab.url?.scheme == "https" ? "lock.fill" : "globe"))
                    .font(.system(size: tab.isPrivate ? 10 : 8, weight: .medium))
                    .foregroundStyle(ink.opacity(tab.isPrivate ? 0.9 : 0.5))
                (Text(Address.displayHost(tab.url)).foregroundColor(ink)
                    + Text(trail).foregroundColor(ink.opacity(0.5)))
                    .font(Design.body(12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 260, maxWidth: 460, minHeight: 23)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink.opacity(0.08))
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(ink.opacity(0.55))
                        .frame(width: geometry.size.width * tab.progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .opacity(tab.isLoading ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: tab.progress)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.url?.absoluteString ?? "")
        // Room for the controls either side when the window is narrow.
        .padding(.horizontal, 190)
    }

    /// Path and query, without the trailing slash a bare site has.
    private var trail: String {
        guard let url = tab.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let path = parts.percentEncodedPath == "/" ? "" : parts.percentEncodedPath
        return path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink.opacity(0.7))
            .frame(width: 26, height: 23)
            .contentShape(Rectangle())
    }
}
