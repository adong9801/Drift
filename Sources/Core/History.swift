import Foundation

struct HistoryEntry: Codable, Equatable {
    var url: String
    var title: String
    var lastVisit: Date
    var visits: Int
}

/// Every page visited, one entry per URL. It exists to feed the command bar,
/// so what it is good at is answering "which page did they mean by these few
/// letters".
struct History: Codable, Equatable {

    static let capacity = 5000

    private(set) var entries: [String: HistoryEntry] = [:]

    /// What searching needs from each entry, worked out once when the entry
    /// changes rather than on every keystroke: parsing five thousand URLs and
    /// lower-casing five thousand titles per letter typed is where the command
    /// bar's time went. Not saved; rebuilt on load.
    private struct Searchable {
        let haystack: String
        let host: String
    }
    private var index: [String: Searchable] = [:]

    private enum CodingKeys: String, CodingKey { case entries }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([String: HistoryEntry].self, forKey: .entries)
        for entry in entries.values { reindex(entry) }
    }

    private mutating func reindex(_ entry: HistoryEntry) {
        index[entry.url] = Searchable(
            haystack: (entry.url + " " + entry.title).lowercased(),
            host: Self.host(of: entry.url)
        )
    }

    static func == (lhs: History, rhs: History) -> Bool { lhs.entries == rhs.entries }

    mutating func record(url: URL, title: String, now: Date = Date()) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        if var existing = entries[key] {
            existing.visits += 1
            existing.lastVisit = now
            let retitled = !title.isEmpty && title != existing.title
            if retitled { existing.title = title }
            entries[key] = existing
            if retitled { reindex(existing) }
        } else {
            let entry = HistoryEntry(url: key, title: title, lastVisit: now, visits: 1)
            entries[key] = entry
            reindex(entry)
            trim()
        }
    }

    /// A page's title usually arrives after the visit is recorded.
    mutating func retitle(url: URL, title: String) {
        guard !title.isEmpty, var entry = entries[url.absoluteString], entry.title != title else { return }
        entry.title = title
        entries[entry.url] = entry
        reindex(entry)
    }

    mutating func clear() {
        entries.removeAll()
        index.removeAll()
    }

    private mutating func trim() {
        guard entries.count > Self.capacity else { return }
        let oldest = entries.values.sorted { $0.lastVisit < $1.lastVisit }.prefix(entries.count - Self.capacity)
        for entry in oldest {
            entries[entry.url] = nil
            index[entry.url] = nil
        }
    }

    // MARK: - Browsing it

    /// Pages by how often and how lately they are visited: what to offer
    /// before anything has been typed.
    func frequent(limit: Int = 8, now: Date = Date()) -> [HistoryEntry] {
        entries.values
            .map { ($0, score($0, words: [], now: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.url < $1.0.url }
            .prefix(limit)
            .map(\.0)
    }

    /// The latest visits, newest first.
    func recent(limit: Int = 15) -> [HistoryEntry] {
        entries.values
            .sorted { $0.lastVisit != $1.lastVisit ? $0.lastVisit > $1.lastVisit : $0.url < $1.url }
            .prefix(limit)
            .map { $0 }
    }

    mutating func forget(url: String) {
        entries[url] = nil
        index[url] = nil
    }

    // MARK: - Matching

    /// Entries in which every word of the query appears, best first.
    func matches(_ query: String, limit: Int = 6, now: Date = Date()) -> [HistoryEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return index
            .compactMap { url, searchable -> (HistoryEntry, Double)? in
                guard words.allSatisfy(searchable.haystack.contains), let entry = entries[url] else { return nil }
                return (entry, score(entry, words: words, now: now))
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.url < $1.0.url }
            .prefix(limit)
            .map(\.0)
    }

    /// The page to offer before anything else: one whose host starts with what
    /// was typed, so "git" plus Return goes to github.com.
    func topHit(_ query: String, now: Date = Date()) -> HistoryEntry? {
        let text = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, !text.contains(" ") else { return nil }
        return entries.values
            .filter { index[$0.url]?.host.hasPrefix(text) ?? false }
            .max { lhs, rhs in
                // Prefer the site's front page over some deep link into it.
                let left = score(lhs, words: [text], now: now) - Double(Self.depth(of: lhs.url)) * 2
                let right = score(rhs, words: [text], now: now) - Double(Self.depth(of: rhs.url)) * 2
                return left != right ? left < right : lhs.url > rhs.url
            }
    }

    /// Often and lately both count; lately fades with a half-life of a week.
    private func score(_ entry: HistoryEntry, words: [String], now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        let recency = pow(0.5, days / 7)
        var value = log2(Double(entry.visits) + 1) * (0.4 + recency)
        if !words.isEmpty, let host = index[entry.url]?.host, words.contains(where: host.hasPrefix) { value += 3 }
        return value
    }

    static func host(of url: String) -> String {
        var host = URL(string: url)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func depth(of url: String) -> Int {
        guard let parts = URLComponents(string: url) else { return 0 }
        let segments = parts.path.split(separator: "/").count
        return segments + (parts.query == nil ? 0 : 1)
    }
}

/// Visit order, most recent first. Drives Ctrl-Tab.
struct RecentOrder<ID: Hashable> {
    private(set) var ids: [ID] = []

    mutating func touch(_ id: ID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
    }

    mutating func remove(_ id: ID) {
        ids.removeAll { $0 == id }
    }

    /// Puts `id` just behind the front, or behind the last of `queued` that
    /// already sits there: what a tab opened in the background gets, so that
    /// Ctrl-Tab goes to it next, and several opened in a row are reached in
    /// the order they were opened.
    mutating func queue(_ id: ID, behind queued: Set<ID>) {
        ids.removeAll { $0 == id }
        var at = min(1, ids.count)
        while at < ids.count, queued.contains(ids[at]) { at += 1 }
        ids.insert(id, at: at)
    }

    /// The recency order restricted to what still exists, with anything never
    /// visited tacked on the end in its own order.
    func ordered(existing: [ID]) -> [ID] {
        let alive = Set(existing)
        let seen = ids.filter(alive.contains)
        let known = Set(seen)
        return seen + existing.filter { !known.contains($0) }
    }
}
