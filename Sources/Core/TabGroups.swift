import Foundation

/// A named, coloured set of tabs. Collapsed, it is one stacked card in
/// Ctrl-Tab and one folded row in the sidebar; expanded, its tabs show one by
/// one. The same switch does both.
struct TabGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var color: GroupColor
    var collapsed: Bool
}

enum GroupColor: String, Codable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, grey

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The next colour along from those taken, so groups made one after
    /// another do not look alike.
    static func next(after taken: [GroupColor]) -> GroupColor {
        allCases.first { !taken.contains($0) } ?? allCases[taken.count % allCases.count]
    }
}

/// How groups appear in Ctrl-Tab. A setting.
enum SwitcherGrouping: String, CaseIterable {
    /// A collapsed group is one stacked card where its latest tab would be.
    case stacked
    /// The latest tabs in a row, then a labelled row for each group.
    case rows
    /// Every tab a card of its own, as if there were no groups.
    case off

    private static let key = "drift.switcherGrouping.v1"

    static var current: SwitcherGrouping {
        get { UserDefaults.standard.string(forKey: key).flatMap(SwitcherGrouping.init(rawValue:)) ?? .stacked }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var label: String {
        switch self {
        case .stacked: return "Stacked"
        case .rows: return "In rows"
        case .off: return "Off"
        }
    }
}

/// One card in Ctrl-Tab: a tab, or a whole group stacked up.
enum SwitcherEntry: Hashable {
    case tab(UUID)
    case group(UUID)
}

/// A run of cards under one heading, or none.
struct SwitcherSection: Equatable {
    var title: String?
    var group: UUID?
    var entries: [SwitcherEntry]
}

enum SwitcherLayout {

    /// The latest tabs shown above the groups, in rows mode.
    static let recentCount = SwitcherGrid.columns

    /// `recent` is every tab, most recently used first: the tab in front, then
    /// the one before it. `openGroup` is shown expanded whatever its setting:
    /// the group of the tab in front, so a quick tap of Ctrl-Tab still flips
    /// to the tab before it rather than to a stack holding both.
    static func sections(
        recent: [UUID],
        groupOf: [UUID: UUID],
        groups: [TabGroup],
        mode: SwitcherGrouping,
        openGroup: UUID?
    ) -> [SwitcherSection] {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func group(of tab: UUID) -> TabGroup? { groupOf[tab].flatMap { byID[$0] } }
        func stacked(_ group: TabGroup) -> Bool { group.collapsed && group.id != openGroup }
        func members(_ group: TabGroup) -> [UUID] { recent.filter { groupOf[$0] == group.id } }

        switch mode {
        case .off:
            return [SwitcherSection(title: nil, group: nil, entries: recent.map(SwitcherEntry.tab))]

        case .stacked:
            // Each group where its latest tab falls: as a stack, or with all
            // its tabs side by side, latest first.
            var entries: [SwitcherEntry] = []
            var placed = Set<UUID>()
            for id in recent {
                guard let group = group(of: id) else { entries.append(.tab(id)); continue }
                guard placed.insert(group.id).inserted else { continue }
                entries += stacked(group) ? [.group(group.id)] : members(group).map(SwitcherEntry.tab)
            }
            return [SwitcherSection(title: nil, group: nil, entries: entries)]

        case .rows:
            let latest = Array(recent.prefix(recentCount))
            var sections = [SwitcherSection(title: groups.isEmpty ? nil : "Recent", group: nil, entries: latest.map(SwitcherEntry.tab))]
            var seen = Set<UUID>()
            for id in recent {
                guard let group = group(of: id), seen.insert(group.id).inserted else { continue }
                let entries = stacked(group) ? [SwitcherEntry.group(group.id)] : members(group).map(SwitcherEntry.tab)
                sections.append(SwitcherSection(title: group.name, group: group.id, entries: entries))
            }
            let others = recent.dropFirst(recentCount).filter { group(of: $0) == nil }
            if !others.isEmpty {
                sections.append(SwitcherSection(title: "Other tabs", group: nil, entries: others.map(SwitcherEntry.tab)))
            }
            return sections
        }
    }

    /// Where the overlay opens: on the card holding the tab before this one,
    /// or, going backwards, on the last card.
    static func openingIndex(entries: [SwitcherEntry], recent: [UUID], groupOf: [UUID: UUID], backwards: Bool) -> Int {
        if backwards { return max(0, entries.count - 1) }
        guard recent.count > 1 else { return 0 }
        let previous = recent[1]
        return entries.firstIndex { entry in
            switch entry {
            case .tab(let id): return id == previous
            case .group(let id): return groupOf[previous] == id
            }
        } ?? min(1, entries.count - 1)
    }

    /// Rows of at most five, each section starting a row of its own.
    static func rowLengths(_ sections: [SwitcherSection]) -> [Int] {
        sections.flatMap { section in
            stride(from: 0, to: section.entries.count, by: SwitcherGrid.columns).map {
                min(SwitcherGrid.columns, section.entries.count - $0)
            }
        }
    }
}
