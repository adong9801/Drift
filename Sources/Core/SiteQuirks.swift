import Foundation

/// Small corrections for particular sites, applied as the page loads. Each one
/// is here because something concrete broke, and says what.
enum SiteQuirks {

    struct Quirk {
        let hosts: [String]
        let css: String
    }

    static let all: [Quirk] = [
        // Microsoft's sign-in does not use the placeholder attribute. It lays a
        // <div> with the hint text over the empty input, inside a wrapper that
        // covers it too. Password managers test whether a field is hidden
        // behind another element by asking what is at its centre, get the div,
        // and conclude the field is not visible. Bitwarden then builds an empty
        // fill script and does nothing, with no error. Making the two layers
        // transparent to the pointer fixes the test, and costs nothing: a click
        // on the hint now lands on the input it was covering.
        Quirk(
            hosts: [
                "login.microsoftonline.com", "login.microsoft.com", "login.live.com",
                "login.microsoftonline.us", "login.partner.microsoftonline.cn",
            ],
            css: ".placeholderContainer .placeholderInnerContainer, .placeholderContainer .placeholder { pointer-events: none !important; }"
        ),
    ]

    static func css(for host: String) -> String? {
        let name = host.lowercased()
        let matches = all.filter { $0.hosts.contains(name) }.map(\.css)
        return matches.isEmpty ? nil : matches.joined(separator: "\n")
    }

    /// One script for every page. It looks its own host up and leaves at once
    /// on any site with no quirk. A constructed style sheet rather than a
    /// <style> element, because these are exactly the pages whose content
    /// security policy refuses inline styles.
    static var script: String {
        let table = all.map { quirk -> String in
            let hosts = quirk.hosts.map { "\"\($0)\"" }.joined(separator: ",")
            let css = quirk.css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "{hosts:[\(hosts)],css:\"\(css)\"}"
        }.joined(separator: ",")
        return """
        (function () {
          var quirks = [\(table)];
          var host = location.hostname.toLowerCase();
          var css = quirks.filter(function (q) { return q.hosts.indexOf(host) >= 0; }).map(function (q) { return q.css; }).join("\\n");
          if (!css) return;
          try {
            var sheet = new CSSStyleSheet();
            sheet.replaceSync(css);
            document.adoptedStyleSheets = Array.prototype.concat.call(document.adoptedStyleSheets || [], [sheet]);
          } catch (e) {
            var style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          }
        })();
        """
    }
}
