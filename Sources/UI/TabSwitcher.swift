import SwiftUI

/// Ctrl-Tab: the open tabs as pictures, most recently used first, five to a
/// row. Hold Control, tap Tab to step, let go to land; the arrows move about
/// the grid.
struct TabSwitcher: View {
    @ObservedObject var store: BrowserStore
    let state: Switcher

    private let spacing: CGFloat = 14
    private let padding: CGFloat = 18

    var body: some View {
        let tabs = state.order.compactMap(store.tab)
        let rows = stride(from: 0, to: tabs.count, by: SwitcherGrid.columns).map {
            Array(tabs[$0..<min($0 + SwitcherGrid.columns, tabs.count)])
        }
        GeometryReader { geometry in
            // Five always fit: the cards give up width before a row gives up a card.
            let columns = CGFloat(SwitcherGrid.columns)
            let room = geometry.size.width - 80 - padding * 2 - spacing * (columns - 1)
            let cardWidth = min(220, max(96, room / columns))
            let rowHeight = SwitcherCard.height(forWidth: cardWidth)
            let across = CGFloat(min(tabs.count, SwitcherGrid.columns))
            let width = across * cardWidth + max(0, across - 1) * spacing + padding * 2
            let content = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * spacing + padding * 2

            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                    // A click on the backdrop puts the overlay away.
                    .contentShape(Rectangle())
                    .onTapGesture { store.cancelSwitcher() }

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: spacing) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                                HStack(alignment: .top, spacing: spacing) {
                                    ForEach(Array(row.enumerated()), id: \.element.id) { column, tab in
                                        SwitcherCard(
                                            tab: tab,
                                            lit: rowIndex * SwitcherGrid.columns + column == state.index,
                                            width: cardWidth
                                        )
                                        .id(tab.id)
                                        .onHover { inside in
                                            if inside { store.hoverSwitcher(rowIndex * SwitcherGrid.columns + column) }
                                        }
                                        .onTapGesture {
                                            store.hoverSwitcher(rowIndex * SwitcherGrid.columns + column)
                                            store.commitSwitcher()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(padding)
                    }
                    .onChange(of: state.index) { _, index in
                        guard tabs.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(tabs[index].id, anchor: .center) }
                    }
                }
                // Hugs its cards, and only scrolls once there are more rows
                // than the window has room for.
                .frame(width: width, height: min(content, geometry.size.height - 100))
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Design.border, lineWidth: 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct SwitcherCard: View {
    @ObservedObject var tab: Tab
    let lit: Bool
    let width: CGFloat
    /// Decoded when the card appears and dropped with it; see `Tab.thumbnailData`.
    @State private var picture: NSImage?

    /// The picture keeps a browser window's proportions at any width.
    private var pictureHeight: CGFloat { (width * 0.627).rounded() }

    /// Picture, gap, and one line of title.
    static func height(forWidth width: CGFloat) -> CGFloat { (width * 0.627).rounded() + 8 + 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(width: width, height: pictureHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(lit ? Design.accent : Design.border, lineWidth: lit ? 3 : 1)
                }

            HStack(spacing: 6) {
                FaviconView(image: tab.favicon, size: 14)
                Text(tab.displayTitle)
                    .font(Design.body(12, weight: lit ? .semibold : .regular))
                    .foregroundStyle(lit ? Design.text : Design.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, height: 16, alignment: .leading)
        }
        .scaleEffect(lit ? 1 : 0.96)
        .animation(.easeOut(duration: 0.1), value: lit)
        .onAppear { picture = tab.thumbnail }
        .onChange(of: tab.thumbnailData) { _, _ in picture = tab.thumbnail }
    }

    @ViewBuilder
    private var preview: some View {
        if let picture {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: pictureHeight, alignment: .top)
        } else {
            // Not visited since launch, so there is nothing to show yet.
            ZStack {
                Design.chrome
                VStack(spacing: 8) {
                    FaviconView(image: tab.favicon, size: 32)
                    Text(Address.displayHost(tab.url))
                        .font(Design.body(11))
                        .foregroundStyle(Design.tertiary)
                        .lineLimit(1)
                }
                .padding(12)
            }
        }
    }
}
