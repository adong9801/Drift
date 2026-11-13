import Foundation

/// Content rules that only private tabs get.
///
/// YouTube tags every anonymous visitor with a cookie on first contact and,
/// from a network it distrusts (a VPN, here), then refuses that visitor
/// playback: "Video unavailable" for every video. A signed-in account is
/// exempt, which is why the ordinary window is fine and the private one is
/// not. Sent no cookies at all, YouTube treats each request as a first visit
/// and plays. Private tabs keep nothing anyway, so nothing is lost but the
/// chance to sign in to YouTube there.
enum PrivateRules {

    static let identifier = "drift-private-rules-v1"

    /// The hosts YouTube's player talks to.
    static let cookielessHosts = ["youtube.com", "youtube-nocookie.com", "googlevideo.com", "ytimg.com", "ggpht.com"]

    static var json: String {
        let domains = cookielessHosts.map { "\"*\($0)\"" }.joined(separator: ",")
        return #"[{"trigger":{"url-filter":".*","if-domain":[\#(domains)]},"action":{"type":"block-cookies"}}]"#
    }
}
