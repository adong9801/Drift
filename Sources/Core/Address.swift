import Foundation

/// Decides what typed text means: somewhere to go, or something to search for.
enum Address {

    static let searchTemplate = "https://www.google.com/search?q="

    /// A URL if the text reads as one, nil if it reads as a search.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        let lowered = text.lowercased()
        for scheme in ["http://", "https://", "file://", "about:"] where lowered.hasPrefix(scheme) {
            return URL(string: text)
        }
        // "foo:bar" with no slashes is a search, not a scheme, unless the part
        // after the colon is a port.
        let hostPart = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let pieces = hostPart.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count <= 2, let host = pieces.first, !host.isEmpty else { return nil }
        if pieces.count == 2, Int(pieces[1]) == nil { return nil }

        if host == "localhost" || isIPv4(host) {
            return URL(string: "http://" + text)
        }
        guard looksLikeDomain(host) else { return nil }
        return URL(string: "https://" + text)
    }

    /// Where the text leads: the URL it names, or a search for it.
    static func destination(for input: String) -> URL? {
        if let direct = url(from: input) { return direct }
        return searchURL(for: input)
    }

    static func searchURL(for query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let escaped = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        return URL(string: searchTemplate + escaped)
    }

    /// At least two labels, legal characters, and a last label that could be a
    /// TLD. "readme.md" passes and that is fine: it is what every browser does.
    private static func looksLikeDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.count >= 2 else { return false }
        guard last.allSatisfy({ $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    /// The short form shown in the sidebar: the host without "www.".
    static func displayHost(_ url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
