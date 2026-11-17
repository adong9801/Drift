import SwiftUI

/// The window: sidebar, one page or two, and the overlays that float above
/// them. The page sits inset in the window's own colour with rounded corners,
/// so the chrome reads as a frame round the content instead of bars on top.
struct BrowserWindow: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var extensions = Extensions.shared
    @ObservedObject private var quit = QuitHold.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let tab = store.fullscreenTab {
                // A page in full screen: nothing of Drift's round it.
                WebPane(tab: tab)
                    .background(Color.black)
            } else if store.sidebarVisible {
                // Two rounded shapes side by side on a sheet of glass, which is
                // the icon: the sidebar floats as a panel of its own, clear of
                // the window's edge, and the page sits beside it.
                HStack(spacing: 0) {
                    Sidebar(store: store)
                        .background { SidebarPanel(fullScreen: store.isFullScreen) }
                        .padding([.leading, .vertical], Design.gutter)
                        .transition(.move(edge: .leading))
                    // Full screen: the page runs to the screen's edges, with
                    // only the gap that separates it from the sidebar.
                    pages
                        .padding(.leading, Design.gutter)
                        .padding([.top, .trailing, .bottom], store.isFullScreen ? 0 : Design.gutter)
                }
                .background {
                    ZStack {
                        // Glass over the desktop. In full screen there is
                        // nothing behind the window to see through to, and
                        // the glass turns black under a grey panel; a plain
                        // surface does then.
                        if store.isFullScreen {
                            Color(nsColor: .underPageBackgroundColor)
                        } else {
                            VisualEffect(material: .underWindowBackground)
                        }
                        // The private window wears its colour, so it is never
                        // mistaken for the ordinary one.
                        if store.isPrivateWindow { Design.privateSoft }
                    }
                }
            } else {
                // No sidebar, so the address moves to a bar across the top, and
                // the bar and frame take the page's own colour.
                VStack(spacing: 0) {
                    if let tab = store.focused {
                        // Per tab, like `FrameTint`: a switch is a cut.
                        TopBar(tab: tab, store: store).id(tab.id)
                    } else {
                        Color.clear.frame(height: TopBar.height)
                    }
                    pages.padding([.horizontal, .bottom], store.isFullScreen ? 0 : Design.gutter)
                }
                .background(FrameTint(tab: store.focused))

                // Pointer at the left edge: the sidebar slides out over the page.
                Color.clear
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { if $0 { store.pointerMoved(x: 0) } }

                if store.sidebarPeek {
                    Sidebar(store: store)
                        // Over the page here, so it is the page that shows
                        // through, blurred. Floating and rounded all the same.
                        .background {
                            RoundedRectangle(cornerRadius: Design.sidebarRadius, style: .continuous)
                                .fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.3), radius: 24, x: 4, y: 6)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.sidebarRadius, style: .continuous)
                                .strokeBorder(Design.border, lineWidth: 1)
                        }
                        .padding(Design.gutter)
                        .onHover { inside in if !inside { store.endPeek() } }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
            }

            if let mode = store.commandBar {
                CommandBar(store: store, mode: mode)
                    // A fresh bar each time, so last time's text is gone.
                    .id(mode)
                    .transition(.opacity)
                    .zIndex(2)
            }
            if let switcher = store.switcher {
                TabSwitcher(store: store, state: switcher)
                    .zIndex(3)
            }
            if quit.holding {
                QuitHint()
                    .transition(.opacity)
                    .zIndex(4)
            }
            if let notice = store.notice {
                NoticeView(notice: notice, store: store)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(4)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.sidebarVisible)
        .animation(.easeOut(duration: 0.12), value: quit.holding)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.notice)
        .animation(.easeOut(duration: 0.15), value: store.fullscreenTab == nil)
        .animation(.easeOut(duration: 0.25), value: store.isFullScreen)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: store.sidebarPeek)
        .animation(.easeOut(duration: 0.1), value: store.commandBar)
        .ignoresSafeArea()
        .background { WindowButtons(store: store) }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pages: some View {
        if !extensions.isReady {
            // A beat at launch, while the extensions load. See `Extensions.isReady`.
            Color.clear
        } else if let primary = store.selected {
            if let secondary = store.split {
                GeometryReader { geometry in
                    let gap: CGFloat = 8
                    let usable = geometry.size.width - gap
                    let left = max(240, min(usable - 240, usable * store.splitRatio))
                    HStack(spacing: 0) {
                        page(primary, pane: .primary).frame(width: left)
                        divider(usable: usable).frame(width: gap)
                        page(secondary, pane: .secondary)
                    }
                }
            } else {
                page(primary, pane: .primary)
            }
        } else {
            emptyState
        }
    }

    private func page(_ tab: Tab, pane: Pane) -> some View {
        let lit = store.split != nil && store.focusedPane == pane
        // Square and unframed in full screen. Two pages side by side keep their
        // round corners even there, since the gap between them is still a frame.
        let framed = !store.isFullScreen || store.split != nil
        let radius = framed ? Design.pageRadius : 0
        return WebPane(tab: tab)
            .overlay { PageVeil(tab: tab).id(tab.id).allowsHitTesting(false) }
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Design.surface)
                    .shadow(color: .black.opacity(framed ? 0.12 : 0), radius: 3, y: 1)
            }
            .overlay {
                // Round corners, painted on rather than masked in.
                if framed {
                    FrameCorners(tab: store.sidebarVisible ? nil : store.focused)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if framed || lit {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(lit ? Design.accent.opacity(0.7) : Design.border, lineWidth: lit ? 2 : 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if store.findVisible, store.focused?.id == tab.id {
                    FindBar(store: store, finder: tab.finder).id(tab.id).padding(12)
                }
            }
    }

    private func divider(usable: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay {
                Capsule().fill(Design.border).frame(width: 3, height: 36)
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin: CGFloat = store.sidebarVisible ? Design.sidebarWidth + Design.gutter * 2 : Design.gutter
                        store.splitRatio = min(0.8, max(0.2, (value.location.x - origin) / max(1, usable)))
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No tabs open")
                .font(Design.body(20, weight: .semibold))
                .foregroundStyle(Design.text)
            Text("\u{2318}T to search, enter an address, or find a tab.")
                .font(Design.body(13))
                .foregroundStyle(Design.secondary)
            Button("New Tab") { store.commandBar = .newTab }
                .controlSize(.large)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sidebar's body: a rounded sheet of glass with a hairline edge, lifted off
/// the window by a soft shadow. The dark shape underneath is never seen; it is
/// only there to cast the shadow, since glass casts none of its own.
struct SidebarPanel: View {
    /// In full screen the panel's glass has nothing behind it either, so it
    /// is drawn as a surface a shade apart from the window's.
    var fullScreen = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.sidebarRadius, style: .continuous)
        ZStack {
            shape
                .fill(Color.black.opacity(fullScreen ? 0.18 : 0.5))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
            if fullScreen {
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            } else {
                VisualEffect(material: .sidebar, rounded: Design.sidebarRadius)
            }
            shape.strokeBorder(Design.border, lineWidth: 1)
        }
    }
}

/// "Hold ⌘Q to quit", in the middle of the window, with a bar that fills.
private struct QuitHint: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            Text("Hold \u{2318}Q to quit")
                .font(Design.body(14, weight: .semibold))
                .foregroundStyle(.white)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white).frame(width: geometry.size.width * progress)
                }
            }
            .frame(width: 160, height: 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.75)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.linear(duration: QuitHold.duration)) { progress = 1 } }
    }
}

/// A faint dark veil over a bright page in dark mode; see `EyeComfort`.
private struct PageVeil: View {
    @ObservedObject var tab: Tab
    @Environment(\.colorScheme) private var scheme
    @AppStorage("drift.dimBrightPages.v1") private var dims = false

    var body: some View {
        let strength = EyeComfort.dimming(luminance: tab.tint?.luminance, darkSurroundings: scheme == .dark, enabled: dims)
        Color.black
            .opacity(strength)
            .animation(.easeOut(duration: 0.3), value: strength)
    }
}

/// "Opened behind: site" or "Link copied", top right, for a moment: under
/// the top bar when there is one, so its buttons stay clear. Clicking it goes
/// to the tab it is about, if it is about one.
private struct NoticeView: View {
    let notice: BrowserStore.Notice
    @ObservedObject var store: BrowserStore

    /// The bar across the top is there when the sidebar is away, unless a
    /// page has the whole window.
    private var topInset: CGFloat {
        if store.fullscreenTab != nil { return 0 }
        return store.sidebarVisible ? Design.gutter : TopBar.height
    }

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    store.dismissNotice()
                    if let id = notice.tabID, let tab = store.tab(id) { store.select(tab) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: notice.symbol).font(.system(size: 16, weight: .semibold))
                        Text(notice.text).font(Design.body(15, weight: .semibold)).lineLimit(1)
                        if notice.tabID != nil {
                            Text("Show").font(Design.body(15)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, Design.gutter + 14)
            .padding(.top, topInset + 14)
            Spacer()
        }
    }
}
