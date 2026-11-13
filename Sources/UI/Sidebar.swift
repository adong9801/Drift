import SwiftUI

/// The left rail: navigation and the address on top, pinned tabs, then the
/// open ones, with downloads at the foot. The address lives here rather than
/// in a toolbar so the page gets the window's full height.
struct Sidebar: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var adBlock = AdBlock.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window buttons, which sit inside the panel's top. In
            // full screen they are tucked away with the menu bar.
            Color.clear.frame(height: store.isFullScreen ? 10 : 32)

            if let tab = store.focused {
                NavigationRow(tab: tab, store: store)
            } else {
                addressPlaceholder
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !store.pinnedTabs.isEmpty {
                        label("Pinned")
                        ForEach(store.pinnedTabs) { TabRow(tab: $0, store: store) }
                        Rectangle()
                            .fill(Design.border)
                            .frame(height: 1)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                    }

                    newTabRow
                    ForEach(store.regularTabs) { TabRow(tab: $0, store: store) }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }

            DownloadsList(downloads: store.downloads)
            footer
        }
        .frame(width: Design.sidebarWidth)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Design.body(11, weight: .semibold))
            .foregroundStyle(Design.tertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private var addressPlaceholder: some View {
        Button { store.commandBar = .newTab } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                Text("Search or enter address").font(Design.body(12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Design.tertiary)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background { RoundedRectangle(cornerRadius: Design.radius, style: .continuous).fill(Design.hover) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private var newTabRow: some View {
        Button { store.commandBar = .newTab } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                Text("New Tab").font(Design.body(13, weight: .medium))
                Spacer(minLength: 0)
                Text("\u{2318}T").font(Design.body(11)).foregroundStyle(Design.tertiary)
            }
            .foregroundStyle(Design.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    /// The ad-block shield, and a word on privacy in that window. Extensions
    /// are not here: they live in the Extensions menu, and in the top bar
    /// when the sidebar is away, so the sidebar stays about tabs.
    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                adBlock.enabled.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: adBlock.enabled ? "shield.lefthalf.filled" : "shield.slash")
                        .font(.system(size: 12, weight: .medium))
                    // Only where there is room: beside the extension buttons
                    // the shield speaks for itself.
                    if store.isPrivateWindow {
                        Text(adBlock.enabled ? "Blocking ads" : "Ads allowed")
                            .font(Design.body(11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(adBlock.enabled ? Design.secondary : Design.tertiary)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help(adBlock.enabled
                ? "Blocking ads\(adBlock.hostCount > 0 ? ": \(adBlock.hostCount) ad and tracker hosts" : ""). Click to turn off; reload to apply."
                : "Ads allowed. Click to block them; reload to apply.")
            Spacer(minLength: 0)
            if store.isPrivateWindow {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold))
                    Text("Private").font(Design.body(11, weight: .semibold))
                }
                .foregroundStyle(Design.privateInk)
                .padding(.trailing, 6)
                .help("Nothing in this window is saved: no history, no cookies kept, no extensions. Closing it ends the session.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Address and navigation

/// Back, forward, reload, and the address pill. Observes the focused tab
/// directly, so a page load redraws this and not the whole sidebar.
private struct NavigationRow: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                // While the sidebar is only peeking, the same button pins it open.
                Button { store.sidebarVisible.toggle() } label: { icon("sidebar.left") }
                    .help(store.sidebarVisible ? "Hide sidebar (\u{2318}S)" : "Keep sidebar open (\u{2318}S)")
                Spacer()
                if tab.hasVideo {
                    Button { tab.pictureInPicture(.toggle) } label: { icon("pip.enter") }
                        .help("Picture in picture (\u{2325}\u{2318}P)")
                }
                Button { tab.goBack() } label: { icon("arrow.left") }.disabled(!tab.canGoBack)
                Button { tab.goForward() } label: { icon("arrow.right") }.disabled(!tab.canGoForward)
                Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                    icon(tab.isLoading ? "xmark" : "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)

            Button { store.commandBar = .current } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.isPrivate ? "eye.slash" : (tab.url?.scheme == "https" ? "lock.fill" : "globe"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tab.isPrivate ? Design.privateInk : Design.tertiary)
                    Text(Address.displayHost(tab.url).isEmpty ? "Search or enter address" : Address.displayHost(tab.url))
                        .font(Design.body(12, weight: .medium))
                        .foregroundStyle(Design.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background {
                    RoundedRectangle(cornerRadius: Design.radius, style: .continuous)
                        .fill(tab.isPrivate ? Design.privateSoft : Design.hover)
                }
                .overlay(alignment: .bottomLeading) {
                    // Load progress, as a line along the pill's foot.
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Design.accent)
                            .frame(width: geometry.size.width * tab.progress, height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .opacity(tab.isLoading ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: tab.progress)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.radius, style: .continuous))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.url?.absoluteString ?? "")
        }
        .padding(.horizontal, 10)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Design.secondary)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .hoverHighlight()
    }
}

// MARK: - Tab rows

private struct TabRow: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @State private var hovering = false

    var body: some View {
        let isPrimary = store.selectedID == tab.id
        let isSplit = store.splitID == tab.id
        let onScreen = isPrimary || isSplit
        let hasFocus = store.focused?.id == tab.id

        HStack(spacing: 9) {
            ZStack {
                FaviconView(image: tab.favicon)
                    // Faded while asleep, so it is no surprise when it reloads.
                    .opacity(tab.isLoading ? 0.35 : (tab.isAsleep ? 0.45 : 1))
                if tab.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16, height: 16)

            Text(tab.displayTitle)
                .font(Design.body(13, weight: onScreen ? .medium : .regular))
                .foregroundStyle(onScreen ? Design.text : Design.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isSplit || (isPrimary && store.splitID != nil) {
                Image(systemName: isSplit ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.tertiary)
            }
            if hovering {
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Design.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .hoverHighlight(radius: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hasFocus ? Design.surface : (onScreen ? Design.selected : (hovering ? Design.hover : Color.clear)))
                .shadow(color: .black.opacity(hasFocus ? 0.08 : 0), radius: 1.5, y: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.select(tab) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { dropped, _ in
            guard let moved = dropped.first.flatMap(UUID.init(uuidString:)).flatMap(store.tab) else { return false }
            store.move(moved, before: tab)
            return true
        }
        .contextMenu {
            if !tab.isPrivate {
                Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab) }
            }
            Button("Open in Split View") { store.putInSplit(tab) }
                .disabled(store.selectedID == tab.id)
            Button("Duplicate") { if let url = tab.url { store.newTab(url, isPrivate: tab.isPrivate) } }
            Button("Copy Link") { store.copyLink(of: tab) }
            Divider()
            Button("Close Tab") { store.close(tab) }
            Button("Close Other Tabs") { store.closeOthers(keeping: tab) }
        }
    }
}

// MARK: - Downloads

private struct DownloadsList: View {
    @ObservedObject var downloads: Downloads

    var body: some View {
        if !downloads.items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Downloads")
                        .font(Design.body(11, weight: .semibold))
                        .foregroundStyle(Design.tertiary)
                    Spacer()
                    Button("Clear") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(Design.body(11))
                        .foregroundStyle(Design.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
                ForEach(downloads.items.prefix(4)) { DownloadRow(item: $0, downloads: downloads) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Design.border).frame(height: 1) }
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let downloads: Downloads

    var body: some View {
        Button { downloads.reveal(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(item.state == .finished ? Design.accent : Design.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(Design.body(12))
                        .foregroundStyle(Design.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.state == .running {
                        ProgressView(value: item.fraction).controlSize(.mini).tint(Design.accent)
                    } else if case .failed(let why) = item.state {
                        Text(why).font(Design.body(10)).foregroundStyle(Design.danger).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(item.state == .finished ? "Show in Finder" : "")
    }

    private var symbol: String {
        switch item.state {
        case .running: return "arrow.down.circle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }
}
