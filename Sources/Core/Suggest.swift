import Foundation

/// One row in the command bar.
struct Suggestion: Equatable, Identifiable {
    enum Action: Equatable {
        /// Jump to a tab that is already open.
        case switchTo(UUID)
        case open(URL)
    }

    enum Kind: Equatable {
        case tab
        /// Chosen before for this same text.
        case learned
        case history
        case address
        case search
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let action: Action

    var id: String {
        switch action {
        case .switchTo(let id): return "tab:\(id.uuidString)"
        case .open(let url): return "\(kind):\(url.absoluteString)"
        }
    }
}

/// Builds the command bar's list. Pure, so the ordering can be pinned down by
/// tests: the first row is what Return does, and it must never be a surprise.
enum Suggest {

    struct OpenTab: Equatable {
        let id: UUID
        let title: String
        let url: String
    }

    static func build(
        input: String,
        tabs: [OpenTab],
        history: History,
        learned: Shortcuts = Shortcuts(),
        remote: [String] = [],
        excluding current: UUID? = nil,
        now: Date = Date()
    ) -> [Suggestion] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        var rows: [Suggestion] = []
        var seen = Set<String>()
        func add(_ row: Suggestion, key: String) {
            guard seen.insert(key).inserted else { return }
            rows.append(row)
        }

        // Nothing typed yet: the places most likely wanted, so the bar is
        // useful the moment it opens.
        guard !text.isEmpty else {
            for entry in history.frequent(limit: 8, now: now) {
                guard let url = URL(string: entry.url) else { continue }
                add(historyRow(entry, url), key: entry.url)
            }
            return rows
        }

        // 1. What Return does. A typed address wins outright; otherwise a site
        //    whose name starts with the text; otherwise a search.
        let remembered = learned.matches(for: text, limit: 3, now: now)
        func learnedRow(_ item: LearnedShortcut) -> Suggestion? {
            guard let url = URL(string: item.url) else { return nil }
            let short = Address.displayHost(url) + (url.path.count > 1 ? url.path : "")
            return Suggestion(kind: .learned, title: item.title.isEmpty ? short : item.title, subtitle: short, action: .open(url))
        }
        if let direct = Address.url(from: text) {
            add(Suggestion(kind: .address, title: text, subtitle: "Open", action: .open(direct)), key: direct.absoluteString)
        } else if let first = remembered.first, let row = learnedRow(first) {
            // What was picked for this text before beats any guess.
            add(row, key: first.url)
        } else if let hit = history.topHit(text, now: now), let url = URL(string: hit.url) {
            add(historyRow(hit, url), key: hit.url)
        }
        if let search = Address.searchURL(for: text), Address.url(from: text) == nil {
            add(Suggestion(kind: .search, title: text, subtitle: "Search Google", action: .open(search)), key: search.absoluteString)
        }

        for item in remembered.dropFirst() {
            if let row = learnedRow(item) { add(row, key: item.url) }
        }

        // 2. Tabs already open: switching beats loading the page again.
        let words = text.lowercased().split(separator: " ").map(String.init)
        for tab in tabs where tab.id != current {
            let haystack = (tab.title + " " + tab.url).lowercased()
            guard words.allSatisfy(haystack.contains) else { continue }
            add(
                Suggestion(
                    kind: .tab,
                    title: tab.title.isEmpty ? tab.url : tab.title,
                    subtitle: "Switch to tab",
                    action: .switchTo(tab.id)
                ),
                key: "tab:" + tab.url
            )
            if rows.count >= 5 { break }
        }

        // 3. Places been before, skipping any that are open right now.
        let openURLs = Set(tabs.map(\.url))
        for entry in history.matches(text, limit: 6, now: now) where !openURLs.contains(entry.url) {
            guard let url = URL(string: entry.url) else { continue }
            add(historyRow(entry, url), key: entry.url)
        }

        // 4. What the search engine guesses is being typed.
        for guess in remote.prefix(4) where guess.lowercased() != text.lowercased() {
            guard let url = Address.searchURL(for: guess) else { continue }
            add(Suggestion(kind: .search, title: guess, subtitle: "Search Google", action: .open(url)), key: url.absoluteString)
        }

        return Array(rows.prefix(10))
    }

    private static func historyRow(_ entry: HistoryEntry, _ url: URL) -> Suggestion {
        let short = Address.displayHost(url) + (url.path.count > 1 ? url.path : "")
        return Suggestion(
            kind: .history,
            title: entry.title.isEmpty ? short : entry.title,
            subtitle: short,
            action: .open(url)
        )
    }

    /// Reads the `["query", ["guess", ...]]` shape the suggest endpoint answers in.
    static func parseRemote(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2,
              let guesses = root[1] as? [String]
        else { return [] }
        return guesses
    }
}
