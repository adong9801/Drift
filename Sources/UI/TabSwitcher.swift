import SwiftUI

/// Ctrl-Tab: the open tabs as pictures, most recently used first, five to a
/// row. Hold Control, tap Tab to step, let go to land; the arrows move about
/// the grid. Tab groups show as the setting has them (see `SwitcherLayout`):
/// a collapsed group as one stacked card, which G or its button opens out.
struct TabSwitcher: View {
    @ObservedObject var store: BrowserStore
    let state: Switcher

    private let spacing: CGFloat = 14
    private let padding: CGFloat = 18
    private let headerHeight: CGFloat = 16

    /// What the panel holds, top to bottom: group headings, rows of cards
    /// (each card with its place in the whole run), and the hint.
    private enum Line: Identifiable {
        case heading(String, TabGroup?)
        case row([(index: Int, entry: SwitcherEntry)])
        case hint

        var id: String {
            switch self {
            case .heading(let title, let group): return "h-\(group?.id.uuidString ?? title)"
            case .row(let cards): return "r-\(cards.first?.index ?? -1)"
            case .hint: return "hint"
            }
        }
    }

    private var lines: [Line] {
        var lines: [Line] = []
        var index = 0
        for section in state.sections {
            if let title = section.title { lines.append(.heading(title, store.group(section.group))) }
            let cards = section.entries.enumerated().map { (index: index + $0.offset, entry: $0.element) }
            for start in stride(from: 0, to: cards.count, by: SwitcherGrid.columns) {
                lines.append(.row(Array(cards[start..<min(start + SwitcherGrid.columns, cards.count)])))
            }
            index += section.entries.count
        }
        if !store.groups.isEmpty, SwitcherGrouping.current != .off { lines.append(.hint) }
        return lines
    }

    var body: some View {
        let lines = self.lines
        GeometryReader { geometry in
            // Five always fit: the cards give up width before a row gives up a card.
            let columns = CGFloat(SwitcherGrid.columns)
            let room = geometry.size.width - 80 - padding * 2 - spacing * (columns - 1)
            let cardWidth = min(220, max(96, room / columns))
            let rowHeight = SwitcherCard.height(forWidth: cardWidth)
            let across = CGFloat(min(SwitcherGrid.columns, state.sections.map(\.entries.count).max() ?? 0))
            let width = max(across * cardWidth + max(0, across - 1) * spacing, 260) + padding * 2
            let content = lines.reduce(CGFloat(0)) { total, line in
                switch line {
                case .row: return total + rowHeight
                case .heading, .hint: return total + headerHeight
                }
            } + CGFloat(max(0, lines.count - 1)) * spacing + padding * 2

            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                    // A click on the backdrop puts the overlay away.
                    .contentShape(Rectangle())
                    .onTapGesture { store.cancelSwitcher() }

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: spacing) {
                            ForEach(lines) { line in
                                switch line {
                                case .heading(let title, let group):
                                    heading(title, group: group)
                                case .row(let cards):
                                    HStack(alignment: .top, spacing: spacing) {
                                        ForEach(cards, id: \.index) { card in
                                            self.card(card.entry, at: card.index, width: cardWidth)
                                                .id(card.index)
                                        }
                                    }
                                case .hint:
                                    Text("G opens or closes a group")
                                        .font(Design.body(11))
                                        .foregroundStyle(Design.tertiary)
                                        .frame(height: headerHeight)
                                }
                            }
                        }
                        .padding(padding)
                    }
                    .onChange(of: state.index) { _, index in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
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

    private func heading(_ title: String, group: TabGroup?) -> some View {
        HStack(spacing: 6) {
            if let group {
                Circle().fill(Design.group(group.color)).frame(width: 8, height: 8)
            }
            Text(title)
                .font(Design.body(12, weight: .semibold))
                .foregroundStyle(Design.secondary)
        }
        .frame(height: headerHeight)
    }

    @ViewBuilder
    private func card(_ entry: SwitcherEntry, at index: Int, width: CGFloat) -> some View {
        let lit = index == state.index
        Group {
            switch entry {
            case .tab(let id):
                if let tab = store.tab(id) {
                    SwitcherCard(
                        tab: tab,
                        lit: lit,
                        width: width,
                        group: SwitcherGrouping.current == .off ? nil : store.group(tab.groupID)
                    )
                }
            case .group(let id):
                if let group = store.group(id) {
                    StackCard(
                        group: group,
                        latest: state.recent.lazy.compactMap { store.tab($0) }.first { $0.groupID == id },
                        count: store.tabs(in: id).count,
                        lit: lit,
                        width: width,
                        open: {
                            store.hoverSwitcher(index)
                            store.toggleSwitcherGroup()
                        }
                    )
                }
            }
        }
        .onHover { inside in
            if inside { store.hoverSwitcher(index) }
        }
        .onTapGesture {
            store.hoverSwitcher(index)
            store.commitSwitcher()
        }
    }
}

/// A collapsed group in Ctrl-Tab: its latest tab's picture in front of two
/// more, in the group's colour, with its name and how many tabs it holds.
private struct StackCard: View {
    let group: TabGroup
    let latest: Tab?
    let count: Int
    let lit: Bool
    let width: CGFloat
    let open: () -> Void
    @State private var picture: NSImage?

    private var pictureHeight: CGFloat { (width * 0.627).rounded() }
    private var color: Color { Design.group(group.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                // Two cards showing behind the front one: a pile, in the
                // group's colour.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.45))
                    .frame(width: width - 28, height: pictureHeight - 14)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.75))
                    .frame(width: width - 14, height: pictureHeight - 14)
                    .offset(y: 7)
                front
                    .frame(width: width, height: pictureHeight - 14)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(lit ? Design.accent : color, lineWidth: lit ? 3 : 1.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button(action: open) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 20)
                                .background { Capsule().fill(color) }
                        }
                        .buttonStyle(.plain)
                        .help("Expand the group (G)")
                        .padding(6)
                    }
                    .offset(y: 14)
            }
            .frame(width: width, height: pictureHeight, alignment: .top)

            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(group.name)
                    .font(Design.body(12, weight: .semibold))
                    .foregroundStyle(lit ? Design.text : Design.secondary)
                    .lineLimit(1)
                Text("\(count) tab\(count == 1 ? "" : "s")")
                    .font(Design.body(11))
                    .foregroundStyle(Design.tertiary)
                    .lineLimit(1)
            }
            .frame(width: width, height: 16, alignment: .leading)
        }
        .scaleEffect(lit ? 1 : 0.96)
        .animation(.easeOut(duration: 0.1), value: lit)
        .onAppear { picture = latest?.thumbnail }
    }

    @ViewBuilder
    private var front: some View {
        if let picture {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: pictureHeight - 14, alignment: .top)
        } else {
            ZStack {
                Design.chrome
                FaviconView(image: latest?.favicon, size: 28)
            }
        }
    }
}

private struct SwitcherCard: View {
    @ObservedObject var tab: Tab
    let lit: Bool
    let width: CGFloat
    /// The group it is in, shown as a tag on its picture.
    var group: TabGroup? = nil
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
                        .strokeBorder(lit ? Design.accent : group.map { Design.group($0.color) } ?? Design.border, lineWidth: lit ? 3 : (group == nil ? 1 : 1.5))
                }
                .overlay(alignment: .topLeading) {
                    if let group {
                        Text(group.name)
                            .font(Design.body(10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background { Capsule().fill(Design.group(group.color)) }
                            .padding(6)
                    }
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
