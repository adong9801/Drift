import Foundation

struct HistoryEntry: Codable, Equatable {
    var url: String
    var title: String
    var lastVisit: Date
    var visits: Int
    /// The last visit on each day the page was visited, oldest first: what
    /// the History page lists, a page once per day, as Chrome's does.
    var days: [Date] = []

    /// At most this many days are kept for any one page.
    static let dayLimit = 90

    mutating func noteVisit(at now: Date, calendar: Calendar = .current) {
        if let last = days.last, calendar.isDate(last, inSameDayAs: now) {
            days[days.count - 1] = max(last, now)
        } else {
            days.append(now)
            // A clock set back puts a day out of order.
            if days.count > 1, days[days.count - 2] > now { days.sort() }
        }
        if days.count > Self.dayLimit { days.removeFirst(days.count - Self.dayLimit) }
    }
}

extension HistoryEntry {
    /// History saved before days were kept has the last visit alone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        lastVisit = try container.decode(Date.self, forKey: .lastVisit)
        visits = try container.decode(Int.self, forKey: .visits)
        days = try container.decodeIfPresent([Date].self, forKey: .days) ?? [lastVisit]
    }
}

/// One line on the History page: a page, on a day, at its last visit that day.
struct HistoryVisit: Equatable {
    let url: String
    let title: String
    let time: Date

    /// The time to the millisecond, which is what the page is handed and
    /// hands back, so a place in the list survives the trip both ways.
    var stamp: Int64 { Self.stamp(time) }
    static func stamp(_ time: Date) -> Int64 { Int64((time.timeIntervalSince1970 * 1000).rounded()) }

    /// Newest first; the address settles a tie.
    static func comesBefore(_ a: (stamp: Int64, url: String), _ b: (stamp: Int64, url: String)) -> Bool {
        a.stamp != b.stamp ? a.stamp > b.stamp : a.url < b.url
    }
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
            existing.noteVisit(at: now)
            let retitled = !title.isEmpty && title != existing.title
            if retitled { existing.title = title }
            entries[key] = existing
            if retitled { reindex(existing) }
        } else {
            let entry = HistoryEntry(url: key, title: title, lastVisit: now, visits: 1, days: [now])
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

    // MARK: - The History page

    /// Visits newest first, a page once a day, after `cursor` (the last one
    /// the page already has) when given. Every word of `query` has to be in
    /// the page's address or title.
    func visits(matching query: String = "", after cursor: (stamp: Int64, url: String)? = nil, limit: Int) -> [HistoryVisit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var found: [HistoryVisit] = []
        for (url, entry) in entries {
            if !words.isEmpty {
                guard let searchable = index[url], words.allSatisfy(searchable.haystack.contains) else { continue }
            }
            for day in entry.days {
                let visit = HistoryVisit(url: url, title: entry.title, time: day)
                if let cursor, !HistoryVisit.comesBefore(cursor, (visit.stamp, url)) { continue }
                found.append(visit)
            }
        }
        found.sort { HistoryVisit.comesBefore(($0.stamp, $0.url), ($1.stamp, $1.url)) }
        return Array(found.prefix(limit))
    }

    /// Takes the given visits out: for each, that page's day. A page left
    /// with no days is gone altogether, so nothing offers it any more.
    /// Returns the addresses that went entirely.
    @discardableResult
    mutating func remove(visits: [(url: String, time: Date)], calendar: Calendar = .current) -> [String] {
        var gone: [String] = []
        for visit in visits {
            guard var entry = entries[visit.url] else { continue }
            entry.days.removeAll { calendar.isDate($0, inSameDayAs: visit.time) }
            if settle(&entry) { gone.append(visit.url) }
        }
        return gone
    }

    /// Takes out every visit from `start` on.
    @discardableResult
    mutating func remove(since start: Date) -> [String] {
        var gone: [String] = []
        for var entry in entries.values where entry.lastVisit >= start || entry.days.contains(where: { $0 >= start }) {
            entry.days.removeAll { $0 >= start }
            if settle(&entry) { gone.append(entry.url) }
        }
        return gone
    }

    /// Puts an entry back after some of its days went, or drops it if none
    /// are left. Whether it was dropped.
    private mutating func settle(_ entry: inout HistoryEntry) -> Bool {
        guard let last = entry.days.last else {
            forget(url: entry.url)
            return true
        }
        entry.lastVisit = last
        entries[entry.url] = entry
        return false
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
