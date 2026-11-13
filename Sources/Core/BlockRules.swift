import Foundation

/// Turns a list of ad and tracker hosts into the JSON WebKit's content blocker
/// compiles. Blocking is by host, the way a hosts file does it, plus a handful
/// of hiding rules for the empty boxes blocked ads leave behind.
///
/// What this cannot do: ads served from the same host as the content. YouTube's
/// are the obvious case, and they need script injection, not request blocking.
enum BlockRules {

    /// Used until a fuller list has been fetched, and if it never can be.
    static let builtIn = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "adnxs.com",
        "adsrvr.org", "amazon-adsystem.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "scorecardresearch.com",
        "quantserve.com", "moatads.com", "adform.net", "bidswitch.net", "smartadserver.com",
        "media.net", "yieldmo.com", "sharethrough.com", "3lift.com", "teads.tv", "zedo.com",
        "advertising.com", "adroll.com", "hotjar.com", "mixpanel.com", "segment.io", "fullstory.com",
        "chartbeat.com", "newrelic.com", "nr-data.net", "bluekai.com", "demdex.net", "everesttech.net",
        "krxd.net", "exelator.com", "rlcdn.com", "crwdcntrl.net", "tapad.com", "mathtag.com",
        "serving-sys.com", "2mdn.net", "adsafeprotected.com", "doubleverify.com", "popads.net",
        "propellerads.com", "revcontent.com", "mgid.com", "onesignal.com", "branch.io",
    ]

    /// Boxes that stay behind, empty, once their ad has been blocked.
    static let hidden = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]",
        "[id^=\"taboola-\"]", ".OUTBRAIN", "[data-ad-slot]", "iframe[src*=\"doubleclick.net\"]",
    ]

    /// One host per line; `#` comments, blank lines and hosts-file prefixes
    /// (`0.0.0.0 host`) are all tolerated. Anything that is not a plain host
    /// name is dropped, since it would end up inside a regular expression.
    static func hosts(fromList text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let host = uncommented.split(separator: " ").last.map({ $0.lowercased() }) else { continue }
            guard isPlainHost(host), seen.insert(host).inserted else { continue }
            result.append(host)
        }
        return result
    }

    static func isPlainHost(_ host: String) -> Bool {
        guard host.contains("."), host != "0.0.0.0", host.count <= 253 else { return false }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    /// The host and everything under it, on either scheme.
    static func filter(for host: String) -> String {
        "^https?://([^/:]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[/:]"
    }

    static func json(hosts: [String], hidden selectors: [String] = hidden) -> String {
        var rules: [[String: Any]] = hosts.map { host in
            [
                // Third-party only: going to one of these sites on purpose
                // still works.
                "trigger": ["url-filter": filter(for: host), "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        if !selectors.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*"],
                "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
