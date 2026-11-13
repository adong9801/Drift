// Checks for the parts of Drift that are plain logic: what typed text means,
// how the command bar orders its rows, history matching, recency order, and the
// ad-block rules. Run with Tests/run.sh.
import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

print("addresses")
check("a bare domain gets https", Address.url(from: "github.com")?.absoluteString == "https://github.com")
check("a path survives", Address.url(from: "github.com/apple/swift")?.absoluteString == "https://github.com/apple/swift")
check("an explicit scheme is kept", Address.url(from: "http://example.com")?.absoluteString == "http://example.com")
check("localhost with a port gets http", Address.url(from: "localhost:3000/app")?.absoluteString == "http://localhost:3000/app")
check("an IP address gets http", Address.url(from: "192.168.1.1")?.absoluteString == "http://192.168.1.1")
check("a domain with a port is an address", Address.url(from: "example.com:8080")?.absoluteString == "https://example.com:8080")
check("words are a search", Address.url(from: "swift concurrency") == nil)
check("one word is a search", Address.url(from: "weather") == nil)
check("a version number is a search", Address.url(from: "3.14") == nil)
check("a colon without a port is a search", Address.url(from: "define:ante") == nil)
check("a question with a dot in it is a search", Address.url(from: "what is node.js") == nil)
check("searches are escaped",
      Address.destination(for: "c++ & rust")?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
check("blank input leads nowhere", Address.destination(for: "   ") == nil)
check("the display host drops www", Address.displayHost(URL(string: "https://www.nytimes.com/section")) == "nytimes.com")

print("history")
do {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day = 86_400.0
    var history = History()
    func visit(_ url: String, _ title: String, times: Int = 1, daysAgo: Double = 0) {
        for _ in 0..<times {
            history.record(url: URL(string: url)!, title: title, now: now.addingTimeInterval(-daysAgo * day))
        }
    }
    visit("https://github.com/", "GitHub", times: 20, daysAgo: 1)
    visit("https://github.com/apple/swift/issues/1234", "Some issue", times: 30, daysAgo: 0)
    visit("https://gitlab.com/", "GitLab", times: 2, daysAgo: 30)
    visit("https://news.ycombinator.com/", "Hacker News", times: 50, daysAgo: 0)
    visit("https://docs.swift.org/swift-book/", "The Swift Programming Language", times: 3, daysAgo: 2)
    history.record(url: URL(string: "file:///tmp/x.html")!, title: "local", now: now)

    check("repeat visits are counted, not duplicated", history.entries["https://github.com/"]?.visits == 20)
    check("non-web pages are not recorded", history.entries.count == 5)
    check("a host prefix finds the site's front page, not a busier deep link",
          history.topHit("git", now: now)?.url == "https://github.com/")
    check("a single letter is too little to guess from", history.topHit("g", now: now) == nil)
    check("no host match means no top hit", history.topHit("zzz", now: now) == nil)
    check("every word has to match", history.matches("swift book", now: now).map(\.url) == ["https://docs.swift.org/swift-book/"])
    check("titles are searched as well as addresses", history.matches("hacker", now: now).first?.url == "https://news.ycombinator.com/")
    check("recent and frequent beats old and rare",
          history.matches("git", now: now).map(\.url).firstIndex(of: "https://gitlab.com/") == 2)
    history.retitle(url: URL(string: "https://gitlab.com/")!, title: "GitLab · DevSecOps")
    check("a late title is filled in", history.entries["https://gitlab.com/"]?.title == "GitLab · DevSecOps")

    print("command bar")
    let tabA = UUID(), tabB = UUID()
    let tabs = [
        Suggest.OpenTab(id: tabA, title: "GitHub", url: "https://github.com/"),
        Suggest.OpenTab(id: tabB, title: "Inbox", url: "https://mail.example.com/"),
    ]
    let typedAddress = Suggest.build(input: "example.org", tabs: tabs, history: history, now: now)
    check("a typed address is what Return does", typedAddress.first?.action == .open(URL(string: "https://example.org")!))
    check("a typed address offers no search row", !typedAddress.contains { $0.kind == .search })

    let words = Suggest.build(input: "swift book", tabs: tabs, history: history, remote: ["swift book pdf"], now: now)
    check("plain words search first", words.first?.kind == .search && words.first?.title == "swift book")
    check("then history", words.dropFirst().first?.kind == .history)
    check("then the engine's guesses", words.last?.title == "swift book pdf")

    let prefix = Suggest.build(input: "news", tabs: tabs, history: history, now: now)
    check("a known site's prefix goes to the site", prefix.first?.action == .open(URL(string: "https://news.ycombinator.com/")!))
    check("with the search still one row down", prefix.dropFirst().first?.kind == .search)

    let open = Suggest.build(input: "inbox", tabs: tabs, history: history, now: now)
    check("an open tab is offered as a switch", open.contains { $0.action == .switchTo(tabB) })
    let current = Suggest.build(input: "inbox", tabs: tabs, history: history, excluding: tabB, now: now)
    check("but not the tab being typed in", !current.contains { $0.action == .switchTo(tabB) })
    let both = Suggest.build(input: "github", tabs: tabs, history: history, now: now)
    check("a page that is open is not also listed from history",
          both.filter { $0.kind == .history && $0.action == .open(URL(string: "https://github.com/")!) }.count <= 1
          && both.contains { $0.action == .switchTo(tabA) })
    check("rows never repeat", Set(both.map(\.id)).count == both.count)
    let blank = Suggest.build(input: "  ", tabs: tabs, history: history, now: now)
    check("nothing typed offers the most visited", blank.first?.action == .open(URL(string: "https://news.ycombinator.com/")!) && blank.allSatisfy { $0.kind == .history })
    check("and nothing at all with no history", Suggest.build(input: "", tabs: tabs, history: History()).isEmpty)
    check("recent history is newest first",
          history.recent(limit: 2).map(\.url) == ["https://github.com/apple/swift/issues/1234", "https://news.ycombinator.com/"]
          || history.recent(limit: 2).map(\.url) == ["https://news.ycombinator.com/", "https://github.com/apple/swift/issues/1234"])

    print("learning")
    var learned = Shortcuts()
    let calendar = URL(string: "https://portal.example.edu/calendar/week")!
    learned.learn(typed: "Cal", url: calendar, title: "School calendar", now: now)
    let first = Suggest.build(input: "cal", tabs: tabs, history: history, learned: learned, now: now)
    check("what was picked for this text comes first", first.first?.action == .open(calendar) && first.first?.kind == .learned)
    check("with the search right behind it", first.dropFirst().first?.kind == .search)
    check("the start of what was typed finds it too",
          Suggest.build(input: "ca", tabs: tabs, history: history, learned: learned, now: now).first?.action == .open(calendar))
    check("so does typing on past it",
          Suggest.build(input: "calendar", tabs: tabs, history: history, learned: learned, now: now).first?.action == .open(calendar))
    check("unrelated text does not", !Suggest.build(input: "swift", tabs: tabs, history: history, learned: learned, now: now).contains { $0.kind == .learned })
    check("a typed address still wins over memory",
          Suggest.build(input: "cal.example.org", tabs: tabs, history: history, learned: learned, now: now).first?.kind == .address)
    check("memory beats the history guess for the same letters", {
        var both = learned
        both.learn(typed: "git", url: URL(string: "https://gitlab.com/")!, title: "GitLab", now: now)
        return Suggest.build(input: "git", tabs: tabs, history: history, learned: both, now: now).first?.action == .open(URL(string: "https://gitlab.com/")!)
    }())
    var habits = Shortcuts()
    let mail = URL(string: "https://mail.example.com/")!, maps = URL(string: "https://maps.example.com/")!
    habits.learn(typed: "ma", url: maps, title: "Maps", now: now.addingTimeInterval(-86_400))
    for _ in 0..<4 { habits.learn(typed: "ma", url: mail, title: "Mail", now: now) }
    check("the page chosen more often leads", habits.matches(for: "ma", now: now).map(\.url) == [mail.absoluteString, maps.absoluteString])
    check("one page is one row however many ways it was reached", {
        var twice = habits
        twice.learn(typed: "mai", url: mail, title: "Mail", now: now)
        return twice.matches(for: "ma", now: now).filter { $0.url == mail.absoluteString }.count == 1
    }())
    habits.forget(url: mail.absoluteString)
    check("a forgotten page stops being offered", habits.matches(for: "ma", now: now).map(\.url) == [maps.absoluteString])
    var pointless = Shortcuts()
    pointless.learn(typed: "github.com", url: URL(string: "https://github.com")!, title: "", now: now)
    pointless.learn(typed: "  ", url: mail, title: "", now: now)
    pointless.learn(typed: "x", url: URL(string: "file:///tmp/a.html")!, title: "", now: now)
    check("typing an address, typing nothing, and local files teach nothing", pointless.items.isEmpty)
    check("the guess endpoint's shape parses",
          Suggest.parseRemote(Data(#"["swi",["swift","swiss","switch"],[],{}]"#.utf8)) == ["swift", "swiss", "switch"])
    check("garbage from the endpoint is no guesses", Suggest.parseRemote(Data("<html>".utf8)).isEmpty)
}

print("recency")
do {
    var recent = RecentOrder<Int>()
    [1, 2, 3].forEach { recent.touch($0) }
    check("the last touched comes first", recent.ordered(existing: [1, 2, 3]) == [3, 2, 1])
    recent.touch(1)
    check("touching again moves to the front", recent.ordered(existing: [1, 2, 3]) == [1, 3, 2])
    check("closed tabs drop out, unvisited ones trail", recent.ordered(existing: [3, 1, 9]) == [1, 3, 9])
    recent.remove(1)
    check("removal is forgotten", recent.ordered(existing: [1, 2, 3]) == [3, 2, 1])
}

print("ad blocking")
do {
    let list = """
    # a comment
    ads.example.com
    0.0.0.0 tracker.example.net   # hosts-file style
    ADS.example.com

    not a host
    bad_host.com
    evil.com/path
    0.0.0.0
    """
    check("hosts parse, deduplicated, junk dropped",
          BlockRules.hosts(fromList: list) == ["ads.example.com", "tracker.example.net"])

    let pattern = BlockRules.filter(for: "doubleclick.net")
    func blocked(_ url: String) -> Bool {
        url.range(of: pattern, options: .regularExpression) != nil
    }
    check("the host is blocked", blocked("https://doubleclick.net/ad.js"))
    check("and its subdomains", blocked("http://stats.g.doubleclick.net:443/x"))
    check("but not a host that merely ends the same", !blocked("https://notdoubleclick.net/"))
    check("nor one that mentions it in a path", !blocked("https://example.com/doubleclick.net/"))
    check("dots are literal", !blocked("https://doubleclickXnet/"))

    let json = BlockRules.json(hosts: ["a.com", "b.net"])
    let rules = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    check("one rule per host plus the hiding rule", rules.count == 3)
    check("blocking is third-party only",
          ((rules.first?["trigger"] as? [String: Any])?["load-type"] as? [String]) == ["third-party"])
    check("the hiding rule hides", ((rules.last?["action"] as? [String: Any])?["type"] as? String) == "css-display-none")
    check("the built-in hosts are all well-formed", BlockRules.builtIn.allSatisfy(BlockRules.isPlainHost))
}

print("page tint")
do {
    let white = PageTint(components: [255, 255, 255])
    let github = PageTint(components: [13, 17, 23])
    let red = PageTint(components: [255, 0, 0])
    let navy = PageTint(components: [20, 40, 120, 1])
    check("white wants dark text", white?.wantsLightText == false)
    check("a near-black page wants light text", github?.wantsLightText == true)
    check("pure red is bright enough for dark text", red?.wantsLightText == false)
    check("navy wants light text, and a fourth component is ignored", navy?.wantsLightText == true)
    check("white's luminance is one", abs((white?.luminance ?? 0) - 1) < 0.0001)
    check("out-of-range channels are clamped", PageTint(components: [300, -5, 128])?.red == 1 && PageTint(components: [300, -5, 128])?.green == 0)
    check("too few numbers is no tint", PageTint(components: [1, 2]) == nil && PageTint(components: []) == nil)
    check("not-a-number is no tint", PageTint(components: [.nan, 0, 0]) == nil)
}

print("extension sources")
do {
    let id = "cndibmoanboadcifjkjbdpjgfedanolh"
    check("a store page gives its id",
          ExtensionSource.storeID(in: "https://chromewebstore.google.com/detail/bettercampus-prev-betterc/\(id)?hl=en") == id)
    check("the old store address works too",
          ExtensionSource.storeID(in: "https://chrome.google.com/webstore/detail/some-name/\(id)") == id)
    check("a bare id is accepted", ExtensionSource.storeID(in: id) == id)
    check("32 letters outside a to p are not an id", ExtensionSource.storeID(in: String(repeating: "z", count: 32)) == nil)
    check("an id on some other site is not trusted", ExtensionSource.storeID(in: "https://evil.example/detail/x/\(id)") == nil)
    check("the download link carries the id",
          ExtensionSource.downloadURL(for: id)?.absoluteString.contains("id%3D\(id)%26uc") == true)
    check("a direct archive link is used as is",
          ExtensionSource.downloadURL(for: "https://github.com/x/y/releases/download/1/ext.safari.zip")?.lastPathComponent == "ext.safari.zip")
    check(".crx and .xpi count as archives",
          ExtensionSource.downloadURL(for: "https://a.example/e.crx") != nil && ExtensionSource.downloadURL(for: "https://a.example/E.XPI") != nil)
    check("plain http is refused", ExtensionSource.downloadURL(for: "http://a.example/e.zip") == nil)
    check("a web page is not an extension", ExtensionSource.downloadURL(for: "https://example.com/about") == nil)

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("drift-src-\(UUID().uuidString)")
    let nested = scratch.appendingPathComponent("my-extension")
    try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    check("no manifest, no root", ExtensionSource.manifestRoot(in: scratch) == nil)
    try? Data("{}".utf8).write(to: nested.appendingPathComponent("manifest.json"))
    check("a manifest one folder down is found",
          ExtensionSource.manifestRoot(in: scratch)?.lastPathComponent == "my-extension")
    try? Data("{}".utf8).write(to: scratch.appendingPathComponent("manifest.json"))
    check("one at the top wins", ExtensionSource.manifestRoot(in: scratch)?.path == scratch.path)
    try? FileManager.default.removeItem(at: scratch)
}

print("site quirks")
do {
    check("Microsoft's sign-in gets its fix", SiteQuirks.css(for: "login.microsoftonline.com")?.contains("pointer-events: none") == true)
    check("the consumer sign-in too, whatever the case", SiteQuirks.css(for: "LOGIN.live.com") != nil)
    check("other Microsoft sites are left alone", SiteQuirks.css(for: "www.microsoft.com") == nil)
    check("a look-alike host gets nothing", SiteQuirks.css(for: "login.microsoftonline.com.evil.example") == nil)
    check("ordinary sites get nothing", SiteQuirks.css(for: "github.com") == nil)
    check("the script carries every host and leaves early elsewhere",
          SiteQuirks.all.flatMap(\.hosts).allSatisfy { SiteQuirks.script.contains("\"\($0)\"") } && SiteQuirks.script.contains("if (!css) return;"))
}

print("tab sleep")
do {
    let quiet = TabSleep.Activity()
    func sleeps(idle: TimeInterval, visible: Bool = false, loading: Bool = false, _ activity: TabSleep.Activity = quiet) -> Bool {
        TabSleep.shouldSleep(idleFor: idle, limit: TabSleep.idleLimit, isVisible: visible, isLoading: loading, activity: activity)
    }
    check("a tab unseen for long enough sleeps", sleeps(idle: TabSleep.idleLimit + 1))
    check("one seen recently does not", !sleeps(idle: 60))
    check("the tab on screen never does", !sleeps(idle: 86_400, visible: true))
    check("nor one still loading", !sleeps(idle: 86_400, loading: true))
    check("music in the background keeps a tab awake", !sleeps(idle: 86_400, TabSleep.Activity(playing: true, edited: false)))
    check("so does something half written", !sleeps(idle: 86_400, TabSleep.Activity(playing: false, edited: true)))
    check("a muted microphone or camera call stays awake", !sleeps(idle: 86_400, TabSleep.Activity(capturing: true)))
    check("a failed activity check stays awake", !sleeps(idle: 86_400, TabSleep.Activity(unknown: true)))
    check("under memory pressure two minutes is enough",
          TabSleep.shouldSleep(idleFor: 150, limit: TabSleep.pressureLimit, isVisible: false, isLoading: false, activity: quiet))
}

print("memory budget")
do {
    let mb: UInt64 = 1_048_576
    check("off has no limit", MemoryBudget.bytes(forMB: 0) == nil)
    check("invalid negative limits are disabled", MemoryBudget.bytes(forMB: -1) == nil)
    check("megabytes convert to bytes", MemoryBudget.bytes(forMB: 2048) == 2048 * mb)
    check("large saved values cannot overflow", MemoryBudget.bytes(forMB: Int.max) == 65_536 * mb)
    check("under budget does not sleep tabs", !MemoryBudget.needsReclaim(bytes: 1000 * mb, limitMB: 1024, reclaiming: false))
    check("at the limit does not sleep tabs", !MemoryBudget.needsReclaim(bytes: 1024 * mb, limitMB: 1024, reclaiming: false))
    check("over budget starts reclamation", MemoryBudget.needsReclaim(bytes: 1025 * mb, limitMB: 1024, reclaiming: false))
    check("reclamation makes ten percent of headroom", MemoryBudget.needsReclaim(bytes: 960 * mb, limitMB: 1024, reclaiming: true))
    check("reclamation stops with headroom", !MemoryBudget.needsReclaim(bytes: 900 * mb, limitMB: 1024, reclaiming: true))
    check("switching off stops even an ongoing reclamation", !MemoryBudget.needsReclaim(bytes: UInt64.max, limitMB: 0, reclaiming: true))
}

print("memory budget default")
do {
    let gb: UInt64 = 1_073_741_824
    check("an 8 GB Mac keeps the 2 GB floor", MemoryBudget.defaultMB(forPhysicalMemoryBytes: 8 * gb) == 2048)
    check("a 16 GB Mac gets 4 GB", MemoryBudget.defaultMB(forPhysicalMemoryBytes: 16 * gb) == 4096)
    check("a 24 GB Mac gets 4 GB too", MemoryBudget.defaultMB(forPhysicalMemoryBytes: 24 * gb) == 4096)
    check("a 32 GB Mac gets 8 GB", MemoryBudget.defaultMB(forPhysicalMemoryBytes: 32 * gb) == 8192)
    check("the default is always one of the choices", MemoryBudget.choices.contains(MemoryBudget.defaultMB))
}

print("private rules")
do {
    let data = PrivateRules.json.data(using: .utf8)!
    let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    check("the private rules are valid JSON with one rule", parsed?.count == 1)
    let action = (parsed?.first?["action"] as? [String: Any])?["type"] as? String
    check("which withholds cookies", action == "block-cookies")
    let domains = ((parsed?.first?["trigger"] as? [String: Any])?["if-domain"] as? [String]) ?? []
    check("from YouTube and the hosts its player uses", domains.contains("*youtube.com") && domains.contains("*googlevideo.com"))
    check("and nothing else", domains.allSatisfy { $0.contains("youtube") || $0.contains("googlevideo") || $0.contains("ytimg") || $0.contains("ggpht") })
}

print("eye comfort")
do {
    check("a white page in dark mode is veiled, and not by much", EyeComfort.dimming(luminance: 1, darkSurroundings: true, enabled: true) == EyeComfort.strongest)
    check("a dark page is not", EyeComfort.dimming(luminance: 0.05, darkSurroundings: true, enabled: true) == 0)
    check("a mid-grey page only slightly", (0.01..<EyeComfort.strongest).contains(EyeComfort.dimming(luminance: 0.4, darkSurroundings: true, enabled: true)))
    check("nothing in light surroundings", EyeComfort.dimming(luminance: 1, darkSurroundings: false, enabled: true) == 0)
    check("nothing when turned off", EyeComfort.dimming(luminance: 1, darkSurroundings: true, enabled: false) == 0)
    check("and it starts turned off", UserDefaults.standard.object(forKey: "drift.dimBrightPages.v1") != nil || !EyeComfort.dimsBrightPages)
    check("nothing before the page's colour is known", EyeComfort.dimming(luminance: nil, darkSurroundings: true, enabled: true) == 0)
}

print("page log")
do {
    var log = PageLog()
    check("starts with nothing to say", log.render() == "nothing logged")
    log.add("nav", "start https://a.example/", at: Date(timeIntervalSince1970: 0))
    log.add("error", "boom", at: Date(timeIntervalSince1970: 1))
    check("keeps what it is told, in order", log.entries.map(\.text) == ["start https://a.example/", "boom"])
    check("renders one line per entry with the level", log.render().split(separator: "\n").count == 2 && log.render().contains("error   boom"))
    log.add("error", String(repeating: "x", count: 5000))
    check("a screenful of stack trace is cut short", log.entries.last!.text.count <= PageLog.lineLimit + 1)
    for i in 0..<400 { log.add("warn", "\(i)") }
    check("only the latest are kept", log.entries.count == PageLog.capacity && log.entries.last?.text == "399")
}

print("recent order queue")
do {
    var order = RecentOrder<String>()
    ["c", "b", "a"].forEach { order.touch($0) }   // a is current, then b, then c
    var queued: Set<String> = []
    order.queue("x", behind: queued); queued.insert("x")
    check("a tab opened behind comes right after the current one", order.ids == ["a", "x", "b", "c"])
    order.queue("y", behind: queued); queued.insert("y")
    check("a second one lines up after the first, in opening order", order.ids == ["a", "x", "y", "b", "c"])
    order.touch("x")
    check("visiting one puts it in front as usual", order.ids == ["x", "a", "y", "b", "c"])
    var empty = RecentOrder<String>()
    empty.queue("only", behind: [])
    check("with nothing open it simply goes first", empty.ids == ["only"])
}

print("switcher grid")
do {
    check("five to a row", SwitcherGrid.rows(for: 5) == 1 && SwitcherGrid.rows(for: 6) == 2 && SwitcherGrid.rows(for: 10) == 2 && SwitcherGrid.rows(for: 11) == 3)
    check("no tabs, no rows", SwitcherGrid.rows(for: 0) == 0)
    check("Tab runs off the end of a row onto the next", SwitcherGrid.step(from: 4, count: 12, backwards: false) == 5)
    check("and wraps from the last card to the first", SwitcherGrid.step(from: 11, count: 12, backwards: false) == 0)
    check("Shift-Tab wraps the other way", SwitcherGrid.step(from: 0, count: 12, backwards: true) == 11)
    check("Down drops a row in the same column", SwitcherGrid.jumpRow(from: 1, count: 12, down: true) == 6)
    check("Up climbs one", SwitcherGrid.jumpRow(from: 6, count: 12, down: false) == 1)
    check("Down onto a short last row lands on its last card", SwitcherGrid.jumpRow(from: 8, count: 12, down: true) == 11)
    check("Down from the last row comes back in at the top", SwitcherGrid.jumpRow(from: 11, count: 12, down: true) == 1)
    check("Up from the top row goes to the bottom", SwitcherGrid.jumpRow(from: 0, count: 12, down: false) == 10)
    check("with one row, Up and Down stay put", SwitcherGrid.jumpRow(from: 2, count: 4, down: true) == 2)
    check("every move lands on a real card", (0..<13).allSatisfy { i in
        [true, false].allSatisfy { down in (0..<13).contains(SwitcherGrid.jumpRow(from: i, count: 13, down: down)) }
    })
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
