import Foundation

/// Something the user typed, and where they then chose to go.
struct LearnedShortcut: Codable, Equatable {
    var typed: String
    var url: String
    var title: String
    var uses: Int
    var lastUsed: Date
}

/// The command bar's memory. Type "cal", pick the school calendar three rows
/// down, and next time "cal" offers the calendar first. History can only guess
/// from what a page is called; this knows what the user meant, because they
/// said so.
struct Shortcuts: Codable, Equatable {

    static let capacity = 600

    private(set) var items: [LearnedShortcut] = []

    static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    mutating func learn(typed: String, url: URL, title: String, now: Date = Date()) {
        let text = Self.normalise(typed)
        guard !text.isEmpty, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        // Typing an address and going to it teaches nothing the address bar
        // does not already know.
        if Address.url(from: text)?.absoluteString == url.absoluteString { return }

        let link = url.absoluteString
        if let index = items.firstIndex(where: { $0.typed == text && $0.url == link }) {
            items[index].uses += 1
            items[index].lastUsed = now
            if !title.isEmpty { items[index].title = title }
        } else {
            items.append(LearnedShortcut(typed: text, url: link, title: title, uses: 1, lastUsed: now))
            if items.count > Self.capacity {
                items.sort { $0.lastUsed > $1.lastUsed }
                items.removeLast(items.count - Self.capacity)
            }
        }
    }

    /// Shift-Delete on a row: stop suggesting that page for anything.
    mutating func forget(url: String) {
        items.removeAll { $0.url == url }
    }

    mutating func clear() { items.removeAll() }

    /// Pages learned for this text or for something it is the start of, best
    /// first, one row per page.
    func matches(for input: String, limit: Int = 3, now: Date = Date()) -> [LearnedShortcut] {
        let text = Self.normalise(input)
        guard !text.isEmpty else { return [] }

        var best: [String: (LearnedShortcut, Double)] = [:]
        for item in items {
            // "yo" finds what was learned for "yout". The other way round,
            // "youtube" finding "yout", holds only once what was learned is long
            // enough to mean something, and only while the text typed on past
            // it still points at that page.
            let typedIsStart = item.typed.hasPrefix(text)
            let learnedIsStart = item.typed.count >= 2 && text.hasPrefix(item.typed) && Self.stillFits(text, item)
            guard typedIsStart || learnedIsStart else { continue }

            let days = max(0, now.timeIntervalSince(item.lastUsed) / 86_400)
            var score = Double(item.uses) * pow(0.5, days / 30)
            if item.typed == text { score += 2 }
            score += Double(min(text.count, item.typed.count)) / Double(max(text.count, item.typed.count))
            if let existing = best[item.url], existing.1 >= score { continue }
            best[item.url] = (item, score)
        }
        return best.values
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.url < $1.0.url }
            .prefix(limit)
            .map(\.0)
    }

    /// Whether every word of the text starts a word of the page's title or
    /// address, or of what was learned. With "do" learned for Google Docs,
    /// "docs" still means it; "does sophia die in lupin" is a question.
    private static func stillFits(_ text: String, _ item: LearnedShortcut) -> Bool {
        let page = words(in: item.title + " " + item.url + " " + item.typed)
        return words(in: text).allSatisfy { word in page.contains { $0.hasPrefix(word) } }
    }

    private static func words(in text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
