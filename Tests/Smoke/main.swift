// Drives the real browser, offscreen: loads a page over the network, checks
// the tab picked up its title, history, thumbnail and session, steps Ctrl-Tab,
// splits the view, compiles the ad-block list, and writes pictures of the
// window to .build/shots. No window is ever shown and the real profile is
// never touched (DRIFT_DATA_DIR). Run with Tests/smoke.sh.
import AppKit
import SwiftUI
import WebKit

let out = CommandLine.arguments[1]
var failures = 0
/// Checks that play sound or open a picture-in-picture window, which a
/// person at the Mac would see and hear. Off unless asked for, so a run can
/// go on behind someone's back. See Tests/README.md.
let mediaChecks = ProcessInfo.processInfo.environment["DRIFT_SMOKE_MEDIA"] == "1"

/// No sound from this web view, whatever plays in it.
@MainActor func quiet(_ view: WKWebView) {
    let selector = NSSelectorFromString("_setPageMuted:")
    guard view.responds(to: selector), let implementation = view.method(for: selector) else { return }
    typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    unsafeBitCast(implementation, to: SetMuted.self)(view, selector, 1)
}

func check(_ label: String, _ condition: Bool) {
    print("  \(condition ? "ok  " : "FAIL") \(label)")
    if !condition { failures += 1 }
}

/// A page that says it is in full screen, which a real one only does with a
/// window on a real screen.
final class FullScreenPage: WKWebView {
    var pretendFullScreen = false
    override var fullscreenState: WKWebView.FullscreenState { pretendFullScreen ? .inFullscreen : .notInFullscreen }
}

/// Stands in for the page: counts the key presses that reach it.
final class KeyRecorder: NSView {
    var received: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
}

/// Borderless windows refuse key status by default, and keys go to the key window.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let store = BrowserStore.shared
    let window = KeyableWindow(
        contentRect: CGRect(x: -30000, y: -30000, width: 1280, height: 800),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    window.contentView = host
    // Ordered in but far off any screen: WebKit will not paint into a window
    // that is not in the window list at all.
    window.orderBack(nil)

    func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func shot(_ name: String) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    // As the app does at launch: nothing is shown until extensions are ready.
    var extensionsReady = false
    Task { @MainActor in await PrivateRuleList.shared.prepare(); await Extensions.shared.start(); extensionsReady = true }
    spin(10) { extensionsReady }
    check("with nothing installed, extensions are ready at once", Extensions.shared.isReady)

    print("loading")
    check("starts empty", store.tabs.isEmpty && store.selected == nil)
    let first = store.newTab(URL(string: "https://example.com/")!)
    spin(20) { !first.isLoading && !first.title.isEmpty }
    check("the page loaded and gave its title", first.title == "Example Domain")
    check("the address followed", first.url?.host == "example.com")
    check("the visit went into history", store.history.entries["https://example.com/"]?.title == "Example Domain")

    var agent = ""
    first.webView?.evaluateJavaScript("navigator.userAgent") { value, _ in agent = value as? String ?? "" }
    spin(3) { !agent.isEmpty }
    check("the user agent names Safari", agent.contains("Safari/") && agent.contains("Version/"))

    // Asked when the page has stopped hearing the pointer. WebKit keeps the
    // callback until the page draws; declared wrongly, that alone ends Drift.
    first.askToDraw()
    check("asking a page to draw leaves Drift running and waits for the page", first.pointer.drawAsked != nil)
    spin(3) { first.pointer.drawAsked == nil }
    check("and the page answers once it has drawn", first.pointer.drawAsked == nil)

    spin(2) { first.thumbnail != nil }
    check("a thumbnail was taken for Ctrl-Tab", first.thumbnail != nil)
    shot("one-tab")

    print("page fullscreen")
    // A video inside an ancestor with a transform (and clipping) — how X
    // virtualises its timeline, moving each cell with transform:translateY —
    // used to trap the pinned fullscreen video in that small cell, so it never
    // filled the window. The shim now strips transform/clip from ancestors on
    // the way in. Exercises the real injected script via makeConfiguration.
    let fsView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                           configuration: Tab.makeConfiguration())
    host.addSubview(fsView)
    fsView.loadHTMLString("""
    <!doctype html><html><body style='margin:0;height:100%'>
    <div id=cell style='position:absolute;top:0;left:0;width:360px;height:220px;transform:translateY(120px);overflow:hidden'>
      <video id=v style='width:320px;height:180px'></video></div>
    <div id=plain style='position:absolute;top:460px;left:0;width:360px;height:220px;overflow:hidden'>
      <video id=cv style='width:320px;height:180px'></video></div>
    </body></html>
    """, baseURL: URL(string: "https://example.test/")!)
    // center of the 1280x800 view; a fullscreen video must own that point.
    let fsMeasure = """
    (function(){
      var v=document.getElementById('v'); if(!v) return 'waiting';
      function fills(el){try{el.requestFullscreen();}catch(e){}
        var hit=document.elementFromPoint(640,400)===el;
        try{document.exitFullscreen();}catch(e){} return hit;}
      return JSON.stringify({x:fills(v), yt:fills(document.getElementById('cv')), done:true});
    })()
    """
    var fsResult = ""
    spin(10) {
        fsView.evaluateJavaScript(fsMeasure) { v, _ in if let s = v as? String, s != "waiting" { fsResult = s } }
        return fsResult.contains("done")
    }
    check("fullscreen fills the window through a transformed, clipped ancestor (X)",
          fsResult.contains("\"x\":true"))
    check("fullscreen still fills the window with no transformed ancestor (YouTube)",
          fsResult.contains("\"yt\":true"))
    fsView.removeFromSuperview()

    print("tabs")
    let second = store.newTab(URL(string: "https://www.iana.org/help/example-domains")!)
    spin(20) { !second.isLoading && !second.title.isEmpty }
    check("a second tab loads and takes the screen", store.selected?.id == second.id && !second.title.isEmpty)
    check("it sits after the tab it was opened from", store.tabs.map(\.id) == [first.id, second.id])

    store.advanceSwitcher(backwards: false)
    check("Ctrl-Tab opens on the previous tab", store.switcher?.litTab == first.id)
    spin(0.3)
    shot("switcher")
    store.commitSwitcher()
    check("letting go lands there", store.selected?.id == first.id && store.switcher == nil)
    store.advanceSwitcher(backwards: false)
    store.commitSwitcher()
    check("and again flips back", store.selected?.id == second.id)
    spin(0.2)
    // Taken out of the window, a page is painted afresh on its return, and
    // WebKit holds the app until it has been.
    check("the tab just left stays in the window, hidden, so coming back is a cut",
          first.webView?.window === window && first.webView?.isHidden == true && second.webView?.isHidden == false)

    print("sleeping tabs")
    // `first` is off screen now. Measure what it costs, put it to sleep, wake it.
    @MainActor func webProcess(of tab: Tab) -> Int32? {
        guard let view = tab.webView, view.responds(to: Selector(("_webProcessIdentifier"))) else { return nil }
        return (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
    }
    func residentMB(_ pid: Int32) -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }
    // As far down as the page goes, which on a short page is not far.
    var leftAt = -1.0
    second.webView?.evaluateJavaScript("window.scrollTo(0, 260); window.scrollY") { value, _ in leftAt = (value as? Double) ?? Double(value as? Int ?? 0) }
    spin(3) { leftAt >= 0 }
    spin(0.5)
    store.select(first)
    spin(1)
    let secondProcess = webProcess(of: second)
    let costMB = secondProcess.map(residentMB) ?? 0
    print("       a small page's web process: \(costMB) MB")
    store.sleepIdleTabs(olderThan: 60)
    spin(1.5)
    check("a tab seen a moment ago is left awake", !second.isAsleep)
    store.sleepIdleTabs(olderThan: 0, force: true)
    spin(3) { second.isAsleep }
    check("the tab out of sight goes to sleep", second.isAsleep && second.webView == nil)
    check("the one on screen does not", !first.isAsleep)
    check("it keeps its title, address and preview", second.title == "Example Domains" && second.url?.host == "www.iana.org" && second.thumbnailData != nil)
    spin(3) { secondProcess.map { residentMB($0) == 0 } ?? true }
    check("its web process is gone, and the memory with it", secondProcess.map { residentMB($0) == 0 } ?? false)
    if let data = second.thumbnailData { print("       its preview is \(data.count / 1024) KB as stored") }

    store.select(second)
    // The page comes back when the window next draws, not inside `select`.
    spin(20) { !second.isAsleep && !second.isLoading && second.title == "Example Domains" }
    check("choosing it wakes it on the same page", !second.isAsleep && second.title == "Example Domains")
    if second.isAsleep || second.title != "Example Domains" { print("       asleep=\(second.isAsleep) loading=\(second.isLoading) title='\(second.title)' url=\(second.url?.absoluteString ?? "-") view=\(second.webView != nil)") }
    var offset = -1.0
    spin(6) {
        second.webView?.evaluateJavaScript("window.scrollY") { value, _ in offset = (value as? Double) ?? Double(value as? Int ?? -1) }
        return leftAt > 0 && abs(offset - leftAt) < 2
    }
    check("scrolled to where it was left", leftAt > 0 && abs(offset - leftAt) < 2)
    print("       left at \(Int(leftAt)), woke at \(Int(offset))")

    print("split view")
    store.toggleSplit()
    check("split brings the last tab alongside", store.split?.id == first.id && store.focusedPane == .secondary)
    spin(0.5)
    check("both pages are on screen at once",
          first.webView?.superview != nil && second.webView?.superview != nil
          && first.webView?.superview !== second.webView?.superview)
    shot("split")
    store.close(second)
    check("closing the left page promotes the right", store.selected?.id == first.id && store.split == nil)
    store.reopenClosed()
    check("a closed tab can be brought back", store.tabs.count == 2 && store.selected?.url?.host == "www.iana.org")

    print("command bar")
    store.commandBar = .newTab
    spin(0.4)
    shot("command-bar")
    let rows = Suggest.build(
        input: "exam",
        tabs: store.tabs.map { Suggest.OpenTab(id: $0.id, title: $0.title, url: $0.url?.absoluteString ?? "") },
        history: store.history
    )
    check("typing a visited site's first letters offers it first", rows.first?.action == .open(URL(string: "https://example.com/")!))
    store.dismissCommandBar()

    // Pick the IANA page for "docs" once, and "docs" should lead there after.
    @MainActor func suggestions(_ text: String) -> [Suggestion] {
        Suggest.build(
            input: text,
            tabs: [],
            history: store.history,
            learned: store.shortcuts
        )
    }
    let iana = URL(string: "https://www.iana.org/help/example-domains")!
    check("before it is taught, 'docs' is just a search", suggestions("docs").first?.kind == .search)
    let tabCount = store.tabs.count
    store.commandBar = .newTab
    store.run(Suggestion(kind: .history, title: "Example Domains", subtitle: "", action: .open(iana)), typed: "docs")
    check("choosing a page for some text opens it", store.tabs.count == tabCount + 1 && store.commandBar == nil)
    check("and that text then offers the page first", suggestions("docs").first?.action == .open(iana) && suggestions("do").first?.action == .open(iana))
    check("the lesson is written to disk", FileManager.default.fileExists(atPath: Storage.directory.appendingPathComponent("shortcuts.json").path))
    if let row = suggestions("docs").first { store.forget(row) }
    check("forgetting the row undoes it", suggestions("docs").first?.kind == .search)
    check("an empty bar offers the most visited", suggestions("").isEmpty == false && suggestions("").allSatisfy { $0.kind == .history })
    if let extra = store.tabs.last, store.tabs.count > tabCount { store.close(extra) }

    print("private window")
    @MainActor func ask(_ tab: Tab, _ script: String) -> String {
        var answer: String?
        tab.webView?.evaluateJavaScript(script) { value, error in answer = value.map { "\($0)" } ?? "error: \(error?.localizedDescription ?? "?")" }
        spin(8) { answer != nil }
        return answer ?? "no answer"
    }
    /// A second offscreen window showing a private store, as the app's private window does.
    @MainActor func show(_ secret: BrowserStore) -> NSWindow {
        let panel = KeyableWindow(
            contentRect: CGRect(x: -30000, y: -20000, width: 1100, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.contentView = NSHostingView(rootView: BrowserWindow(store: secret))
        panel.orderBack(nil)
        spin(0.6)
        return panel
    }
    let privateSite = URL(string: "https://example.net/")!
    let mainTabsBefore = store.tabs.count
    let secret = PrivateSession.shared.begin()
    var secretWindow: NSWindow? = show(secret)
    check("the private window has a store of its own", secret !== store && secret.isPrivateWindow && BrowserStore.all.count == 2)
    check("each window's keys and clicks go to its own store",
          BrowserStore.store(for: secretWindow) === secret && BrowserStore.store(for: window) === store)

    let hidden = secret.newTab(privateSite)
    spin(25) { !hidden.isLoading && !hidden.title.isEmpty }
    check("a tab opened in it is private without being asked", hidden.isPrivate && hidden.title == "Example Domain")
    check("and stays out of the main window", store.tabs.count == mainTabsBefore && secret.tabs.count == 1)
    check("it uses an in-memory data store, not the profile's", hidden.webView?.configuration.websiteDataStore.isPersistent == false)
    check("extensions are not attached to it", hidden.webView?.configuration.webExtensionController == nil)
    check("the private rules compiled for it", PrivateRuleList.shared.list != nil)
    // YouTube, which refuses anonymous visitors on this network once it has
    // given them a cookie: a private tab sends none, and the video loads.
    let clip = secret.newTab(URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!)
    // It starts playing by itself; heard only when asked for.
    if !mediaChecks { quiet(clip.materialize()) }
    var clipState = ""
    spin(30) {
        clip.webView?.evaluateJavaScript("(function(){var ps=(window.ytInitialPlayerResponse||{}).playabilityStatus; var v=document.querySelector('video'); return JSON.stringify({playability: ps? ps.status: null, ready: v? v.readyState: -1, cookies: document.cookie.length});})()") { value, _ in clipState = value as? String ?? "" }
        return clipState.contains("\"ready\":4") || clipState.contains("UNPLAYABLE")
    }
    print("       private YouTube: \(clipState)")
    check("a private YouTube tab gets a playable video, not \u{201c}Video unavailable\u{201d}", clipState.contains("\"playability\":\"OK\"") && clipState.contains("\"ready\":4"))
    // Cookies the page's own script sets may still exist locally; what the
    // rule guarantees is that none are sent, which the playability shows.
    secret.close(clip)
    check("the visit is not in history", store.history.entries[privateSite.absoluteString] == nil)
    _ = ask(hidden, "document.cookie = 'driftprivate=1; max-age=3600; path=/'; localStorage.setItem('driftprivate', '1'); 'set'")

    secret.commandBar = .newTab
    secret.run(Suggestion(kind: .history, title: "Reserved", subtitle: "", action: .open(URL(string: "https://www.iana.org/domains/reserved")!)), typed: "secretword")
    check("its command bar opens private tabs", secret.tabs.count == 2 && secret.tabs.allSatisfy(\.isPrivate))
    check("and teaches the command bar nothing", store.shortcuts.matches(for: "secretword").isEmpty)
    check("but can still read the main window's history to suggest from",
          secret.history.entries.count == store.history.entries.count && !secret.history.entries.isEmpty)

    let ordinary = store.newTab(privateSite)
    spin(25) { !ordinary.isLoading && !ordinary.title.isEmpty }
    check("an ordinary tab on the same site sees none of the private window's cookies or storage",
          ask(ordinary, "String(document.cookie.indexOf('driftprivate') >= 0 || localStorage.getItem('driftprivate') !== null)") == "false")
    _ = ask(ordinary, "document.cookie = 'driftordinary=1; max-age=3600; path=/'; 'set'")

    let sibling = secret.newTab(privateSite)
    spin(25) { !sibling.isLoading && !sibling.title.isEmpty }
    check("tabs in the private window share a session with each other", ask(sibling, "String(document.cookie.indexOf('driftprivate') >= 0)") == "true")
    check("and see nothing of the ordinary profile", ask(sibling, "String(document.cookie.indexOf('driftordinary') >= 0)") == "false")

    store.saveNow()
    secret.saveNow()
    let sessionText = (try? String(contentsOf: Storage.directory.appendingPathComponent("session.json"), encoding: .utf8)) ?? ""
    check("nothing from the private window reaches the session file",
          !sessionText.contains("domains/reserved") && secret.tabs.allSatisfy { !sessionText.contains($0.id.uuidString) })
    check("or history", !store.history.entries.keys.contains { $0.contains("domains/reserved") })

    let privateCount = secret.tabs.count
    secret.close(sibling)
    secret.reopenClosed()
    check("a closed private tab cannot be reopened", secret.tabs.count == privateCount - 1)

    // Closing the window is what ends the session.
    secretWindow?.close()
    spin(0.5)
    if PrivateSession.shared.store != nil { PrivateSession.shared.end() }
    secretWindow = nil
    check("closing the private window ends the session", PrivateSession.shared.store == nil && BrowserStore.all.count == 1 && secret.tabs.isEmpty)

    let next = PrivateSession.shared.begin()
    var nextWindow: NSWindow? = show(next)
    let again = next.newTab(privateSite)
    spin(25) { !again.isLoading && !again.title.isEmpty }
    check("the next private window starts clean: the old private cookies are gone",
          next !== secret && ask(again, "String(document.cookie.indexOf('driftprivate') >= 0 || localStorage.getItem('driftprivate') !== null)") == "false")
    nextWindow?.close()
    spin(0.3)
    if PrivateSession.shared.store != nil { PrivateSession.shared.end() }
    nextWindow = nil
    store.close(ordinary)
    check("and the main window is as it was", store.tabs.count == mainTabsBefore)
    store.select(first)
    spin(0.5)

    print("hidden sidebar")
    spin(3) { first.tint != nil }
    check("a plain page reports a light top colour", first.tint?.wantsLightText == false)
    let darkPage = "data:text/html,%3Cmeta%20name%3Dtheme-color%20content%3D%22%230d1117%22%3E%3Ctitle%3EDark%3C%2Ftitle%3E%3Cbody%20style%3D%22background%3A%230d1117%3Bcolor%3Awhite%3Bfont%3A20px%20system-ui%3Bpadding%3A40px%22%3EA%20dark%20page"
    let dark = store.newTab(URL(string: darkPage)!)
    spin(10) { dark.tint != nil && !dark.isLoading }
    spin(1.5)
    check("a declared theme colour is picked up", dark.tint == PageTint(components: [13, 17, 23]))
    check("and it asks for light text", dark.tint?.wantsLightText == true)

    store.sidebarVisible = false
    spin(0.6)
    shot("hidden-dark")
    store.pointerMoved(x: 200)
    check("the pointer mid-window does not summon the sidebar", !store.sidebarPeek)
    store.pointerMoved(x: 1)
    check("the pointer at the left edge does", store.sidebarPeek)
    spin(0.6)
    shot("hidden-peek")
    store.pointerMoved(x: 180)
    check("it stays while the pointer is over it", store.sidebarPeek)
    store.pointerMoved(x: 400)
    check("and goes when the pointer leaves", !store.sidebarPeek)
    // A popover off the peeking sidebar: leaving the panel for the popover
    // must not put the panel away.
    store.pointerMoved(x: 1)
    store.peekHeld = true
    store.endPeek()
    check("held for a popover, the peek survives the pointer leaving", store.sidebarPeek)
    store.peekHeld = false
    check("and ends once the popover is gone, with the pointer off the window", !store.sidebarPeek)
    store.pointerMoved(x: 1)
    store.sidebarVisible = true
    check("pinning the sidebar ends the peek", !store.sidebarPeek && store.sidebarVisible)
    store.sidebarVisible = false
    store.select(first)
    spin(0.6)
    // The window is off screen, so WebKit paints nothing into it and the shot
    // above shows an empty pane. What can be checked is that the page is
    // attached, unhidden, and has grown into the space the sidebar gave up.
    let pane = first.webView
    check("with the sidebar hidden the page fills the window",
          pane?.window != nil && pane?.isHiddenOrHasHiddenAncestor == false && (pane?.frame.width ?? 0) > 1200)
    check("a body background counts as the page's top colour", first.tint == PageTint(components: [238, 238, 238]))
    store.close(dark)
    store.sidebarVisible = true

    print("keys")
    // Real events through the real dispatch path. Calling the store directly,
    // as the checks above do, cannot tell a swallowed key from one that also
    // went on to the page, and that difference was once a bug.
    let recorder = KeyRecorder(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    host.addSubview(recorder)
    window.makeKey()
    func press(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) {
        window.makeFirstResponder(recorder)
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        app.sendEvent(event)
    }
    press(0, "a")
    let delivers = recorder.received == [0]
    check("an ordinary key reaches the page", delivers)
    recorder.received = []

    store.commandBar = .newTab
    press(53, "\u{1B}")
    check("Escape closes the command bar", store.commandBar == nil)
    check("and goes no further, so it cannot also leave full screen", recorder.received.isEmpty)

    store.commandBar = .newTab
    press(125, "\u{F701}")
    check("the arrows are kept for the command bar's list", recorder.received.isEmpty)
    store.dismissCommandBar()

    let before = store.selected?.id
    press(48, "\t", flags: .control)
    check("Ctrl-Tab opens the switcher", store.switcher != nil)
    check("without also sending a Tab into the page", recorder.received.isEmpty)
    press(59, "", flags: [], type: .flagsChanged)
    check("releasing Control lands on the other tab", store.switcher == nil && store.selected?.id != before)
    // Seven tabs, to see the overlay wrap onto a second row.
    let extras = (1...5).map { n in
        store.newTab(URL(string: "data:text/html,%3Ctitle%3EExtra%20\(n)%3C%2Ftitle%3E%3Cbody%20style%3D%22font%3A40px%20system-ui%3Bpadding%3A60px%3Bbackground%3Ahsl(\(n * 60)%2C60%25%2C85%25)%22%3EExtra%20\(n)")!)
    }
    spin(3)
    store.select(first)
    spin(0.5)
    store.advanceSwitcher(backwards: false)
    check("with seven tabs the overlay has two rows", SwitcherGrid.rows(for: store.switcher?.entries.count ?? 0) == 2)
    let startIndex = store.switcher?.index ?? -1
    store.moveSwitcherRow(down: true)
    check("Down moves to the row beneath, same column", store.switcher?.index == SwitcherGrid.jumpRow(from: startIndex, count: 7, down: true) && store.switcher?.index != startIndex)
    spin(0.4)
    shot("switcher-grid")
    // W in the overlay, through the real key path, with Control still held.
    // Only ever aimed at one of the extra tabs: later checks need the others.
    let spare = Set(extras.map(\.id))
    @MainActor func aimAtSpare() {
        for _ in 0..<8 {
            if let open = store.switcher, open.litTab.map(spare.contains) == true { return }
            store.advanceSwitcher(backwards: false)
        }
    }
    aimAtSpare()
    let doomed = store.switcher?.litTab
    let tabsWithOverlay = store.tabs.count
    press(13, "w", flags: [.control])
    check("Ctrl-W in the overlay closes the highlighted tab", store.tabs.count == tabsWithOverlay - 1 && doomed.map { id in !store.tabs.contains { $0.id == id } } == true)
    check("and the overlay stays up, pointing at a tab that exists",
          store.switcher.map { $0.entries.count == tabsWithOverlay - 1 && $0.entries.indices.contains($0.index) && $0.litTab.flatMap(store.tab) != nil } == true)
    let afterFirst = store.tabs.count
    aimAtSpare()
    press(13, "w", flags: [.control, .command])
    check("adding Command closes one too", store.tabs.count == afterFirst - 1)
    check("and the page never sees the W", recorder.received.isEmpty)
    store.cancelSwitcher()
    extras.filter { tab in store.tabs.contains { $0.id == tab.id } }.forEach(store.close)
    spin(0.3)

    // A tap of Command-Q must not quit: it shows the hold hint and is swallowed.
    recorder.received.removeAll()
    press(12, "q", flags: [.command])
    check("a tap of Command-Q only starts the hold", QuitHold.shared.holding)
    check("and the page never sees it", recorder.received.isEmpty)
    press(12, "q", flags: [.command], type: .keyUp)
    check("letting go before the hold is up cancels it", !QuitHold.shared.holding)
    spin(1.2)
    check("and Drift is still here a second later", store.tabs.count > 0)

    recorder.removeFromSuperview()

    // Middle-click on a link opens it behind, as Command-click does.
    let linkTab = store.newTab(URL(string: "data:text/html,%3Ctitle%3ELink%3C/title%3E%3Ca%20href%3D%22https%3A//example.net/%22%20style%3D%22display%3Ablock%3Bwidth%3A100vw%3Bheight%3A100vh%22%3E%3C/a%3E")!)
    spin(20) { !linkTab.isLoading && !linkTab.title.isEmpty }
    spin(0.5)
    let tabsBeforeClick = store.tabs.count
    if let view = linkTab.webView, let viewWindow = view.window {
        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: viewWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                app.sendEvent(event)
            }
        }
    }
    spin(8) { store.tabs.count > tabsBeforeClick }
    check("middle-click on a link opens it in a new tab", store.tabs.count == tabsBeforeClick + 1 && store.tabs.contains { $0.url?.host == "example.net" })
    print("       page log: \(linkTab.log.render().split(separator: "\n").filter { $0.contains("link click") }.joined(separator: " | "))")
    check("behind the one being read", store.focused === linkTab)
    check("instead of leaving the page", linkTab.url?.scheme == "data")
    store.tabs.filter { $0.url?.host == "example.net" }.forEach(store.close)

    // Command-click, the same way, with a real event.
    let tabsBeforeCommandClick = store.tabs.count
    if let view = linkTab.webView, let viewWindow = view.window {
        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: viewWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                app.sendEvent(event)
            }
        }
    }
    spin(8) { store.tabs.count > tabsBeforeCommandClick }
    check("Command-click on a link opens it in a new tab", store.tabs.count == tabsBeforeCommandClick + 1 && store.tabs.contains { $0.url?.host == "example.net" })
    check("without switching to it", store.focused === linkTab)
    check("with the sidebar up, no notice is needed", store.notice == nil)
    if let behind = store.tabs.first(where: { $0.url?.host == "example.net" }) {
        store.advanceSwitcher(backwards: false)
        check("Ctrl-Tab right after points at the tab just opened behind", store.switcher?.litTab == behind.id)
        store.hoverSwitcher(0)
        check("the pointer over a card highlights it", store.switcher?.index == 0)
        store.cancelSwitcher()
    }
    store.sidebarVisible = false
    let quiet = store.newTab(URL(string: "https://example.net/")!, inBackground: true)
    check("with the sidebar away, a tab opened behind is announced", store.notice?.tabID == quiet.id && store.notice?.text.contains("example.net") == true)
    if let tab = store.notice?.tabID.flatMap({ store.tab($0) }) { store.dismissNotice(); store.select(tab) }
    check("and the notice leads to it", store.focused === quiet && store.notice == nil)
    store.sidebarVisible = true
    store.select(linkTab)
    store.tabs.filter { $0.url?.host == "example.net" }.forEach(store.close)
    store.close(linkTab)

    // A site that turns the click into window.open, as most web apps do:
    // Command held means the new tab still goes behind.
    let openerTab = store.newTab(URL(string: "data:text/html,%3Ctitle%3EOpener%3C/title%3E%3Ca%20href%3D%22%23%22%20onclick%3D%22window.open('https%3A//example.net/'%2C'_blank')%3Breturn%20false%22%20style%3D%22display%3Ablock%3Bwidth%3A100vw%3Bheight%3A100vh%22%3E%3C/a%3E")!)
    spin(20) { !openerTab.isLoading && !openerTab.title.isEmpty }
    spin(0.5)
    let tabsBeforeOpen = store.tabs.count
    if let view = openerTab.webView, let viewWindow = view.window {
        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: viewWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                app.sendEvent(event)
            }
        }
    }
    spin(8) { store.tabs.count > tabsBeforeOpen }
    check("a site's window.open on a Command-click still makes a tab", store.tabs.count == tabsBeforeOpen + 1)
    check("and it too stays behind", store.focused === openerTab)
    store.tabs.filter { $0 !== openerTab && $0.url?.host == "example.net" || ($0 !== openerTab && $0.url == nil) }.forEach(store.close)
    store.close(openerTab)

    // The mouse's side buttons.
    let walker = store.newTab(URL(string: "data:text/html,%3Ctitle%3EOne%3C/title%3EOne")!)
    spin(10) { !walker.isLoading && walker.title == "One" }
    walker.webView?.load(URLRequest(url: URL(string: "data:text/html,%3Ctitle%3ETwo%3C/title%3ETwo")!))
    spin(10) { walker.title == "Two" }
    check("the fourth mouse button goes back", store.mouseButton(3) && { spin(10) { walker.title == "One" }; return walker.title == "One" }())
    check("the fifth goes forward", store.mouseButton(4) && { spin(10) { walker.title == "Two" }; return walker.title == "Two" }())
    check("the middle button is not Drift's to take", !store.mouseButton(2))
    store.close(walker)

    print("waking a sleeping tab")
    // A switch is a cut: the woken page is there at once, as the window's
    // colour until it paints, with nothing of the last page showing. The last
    // page stays behind it, hidden, so going back is a cut as well.
    let wakePane = WebPane.Host(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let older = WKWebView(frame: .zero)
    wakePane.show(older)
    let woken = WKWebView(frame: .zero)
    woken.loadHTMLString("<title>Woke</title>", baseURL: nil)
    wakePane.show(woken)
    func showing(_ pane: NSView) -> [NSView] { pane.subviews.filter { !$0.isHidden } }
    check("the woken page replaces the last one at once", showing(wakePane).count == 1 && showing(wakePane).first === woken && woken.alphaValue == 1)
    check("the last one is kept behind it, hidden", older.superview === wakePane && older.isHidden)
    wakePane.show(older)
    check("and switching back is a cut too", showing(wakePane).count == 1 && showing(wakePane).first === older && older.alphaValue == 1)
    // A drag goes to the topmost page under the pointer, hidden or not.
    check("the page switched back to is on top, so a drop goes to it and not the hidden one", wakePane.subviews.last === older)
    let morePages = (0..<WebPane.Host.warmLimit + 1).map { _ in WKWebView(frame: .zero) }
    morePages.forEach(wakePane.show)
    check("only the last few pages are kept", wakePane.subviews.count == WebPane.Host.warmLimit + 1 && older.superview == nil && woken.superview == nil)
    woken.removeFromSuperview()
    let sleeper = morePages[1]
    sleeper.removeFromSuperview()
    wakePane.show(older)
    check("a page that has left (asleep or closed) is not brought back", sleeper.superview == nil && wakePane.subviews.count <= WebPane.Host.warmLimit + 1)
    // WebKit hands the colour back resolved, so it is compared by value.
    func rgb(_ colour: NSColor?) -> [Int] {
        guard let c = colour?.usingColorSpace(.sRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int($0 * 255) }
    }
    store.select(first)
    spin(0.5)
    check("a page is given the window's colour to wake up in", !rgb(first.webView?.underPageBackgroundColor).isEmpty && rgb(first.webView?.underPageBackgroundColor) == rgb(NSColor.windowBackgroundColor))
    check("pages get no WebGPU, whose workers WebKit leaks once a page is gone", ask(first, "typeof navigator.gpu") == "undefined")

    print("video in full screen")
    // WebKit moves a full-screen page into a window of its own. The videoPane must
    // leave it there, however often the window behind redraws.
    let fullScreenWindow = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    let lifted = FullScreenPage(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
    let videoPane = WebPane.Host(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    videoPane.show(lifted)
    check("a page goes into its pane", lifted.superview === videoPane)
    lifted.pretendFullScreen = true
    fullScreenWindow.contentView?.addSubview(lifted)
    videoPane.show(lifted)
    check("a page WebKit has taken full screen is left where WebKit put it", lifted.superview === fullScreenWindow.contentView)
    lifted.pretendFullScreen = false
    videoPane.show(lifted)
    check("and is taken back only once full screen is over", lifted.superview === videoPane)
    lifted.removeFromSuperview()

    print("full screen inside the window")
    // A page asking for full screen gets Drift's in-window kind: it is told it
    // has it, Drift shows the page alone, and Escape ends it.
    let fsTab = store.newTab(URL(string: "data:text/html,%3Ctitle%3EFS%3C/title%3E%3Cdiv%20id%3D%22player%22%20style%3D%22width%3A200px%3Bheight%3A100px%3Bbackground%3Ared%22%3E%3C/div%3E%3Cscript%3Ewindow.changes%3D0%3Bdocument.addEventListener('fullscreenchange'%2C()%3D%3Ewindow.changes%2B%2B)%3C/script%3E")!)
    spin(20) { !fsTab.isLoading && !fsTab.title.isEmpty }
    @MainActor func page(_ js: String) -> Any? {
        var answer: Any? = "pending"
        fsTab.webView?.evaluateJavaScript(js) { value, error in answer = error.map { "error: \($0.localizedDescription)" } ?? value }
        spin(5) { !(answer is String && answer as? String == "pending") }
        return answer
    }
    check("the page is told full screen is available", page("document.fullscreenEnabled") as? Bool == true)
    _ = page("document.getElementById('player').requestFullscreen(); 0")
    spin(3) { store.fullscreenTab != nil }
    check("asking for it puts the page in front on its own", store.fullscreenTab === fsTab && fsTab.isPageFullscreen)
    check("the page sees its element as the full-screen one", page("document.fullscreenElement && document.fullscreenElement.id") as? String == "player")
    check("and heard fullscreenchange", (page("window.changes") as? Int ?? 0) >= 1)
    check("a video inside it is pinned to the viewport, whatever the site sized it", {
        _ = page("(function(){var v=document.createElement('video'); v.style.cssText='position:absolute;left:900px;top:20px;width:300px;height:200px'; document.getElementById('player').appendChild(v); return 0;})()")
        let rect = page("(function(){var r=document.querySelector('#player video').getBoundingClientRect();return [r.left,r.top,r.width===innerWidth,r.height===innerHeight]})()") as? [Any]
        return rect?.count == 4 && (rect?[0] as? Double) == 0 && (rect?[1] as? Double) == 0 && rect?[2] as? Bool == true && rect?[3] as? Bool == true
    }())
    check("the element now covers the viewport", {
        let rect = page("(function(){var r=document.getElementById('player').getBoundingClientRect();return [r.left,r.top,r.width===innerWidth,r.height===innerHeight]})()") as? [Any]
        return rect?.count == 4 && rect?[2] as? Bool == true && rect?[3] as? Bool == true
    }())
    host.addSubview(recorder)
    recorder.received.removeAll()
    press(53, "\u{1B}")
    spin(3) { store.fullscreenTab == nil }
    check("Escape ends it", store.fullscreenTab == nil && !fsTab.isPageFullscreen)
    check("and the page never sees the Escape", recorder.received.isEmpty)
    recorder.removeFromSuperview()
    check("the page agrees", page("document.fullscreenElement") is NSNull || page("document.fullscreenElement") == nil)
    _ = page("document.getElementById('player').requestFullscreen(); 0")
    spin(3) { store.fullscreenTab != nil }
    store.select(first)
    spin(3) { store.fullscreenTab == nil }
    check("switching tabs ends it too", store.fullscreenTab == nil && !fsTab.isPageFullscreen)
    store.select(fsTab)
    _ = page("document.getElementById('player').requestFullscreen(); 0")
    spin(3) { store.fullscreenTab != nil }
    check("back in full screen for the last check", store.fullscreenTab === fsTab)
    store.close(fsTab)
    check("closing the tab in full screen ends it, with no ghost left on show", store.fullscreenTab == nil && !fsTab.isPageFullscreen && !store.tabs.contains { $0 === fsTab })

    if !mediaChecks {
        print("video: skipped, since it plays sound and opens picture in picture (DRIFT_SMOKE_MEDIA=1 runs it)")
    } else {
    print("video")
    let videoTab = store.newTab(URL(string: "data:text/html,%3Ctitle%3EVideo%3C/title%3E%3Cbody%20style%3D%22margin%3A0%3Bbackground%3A%23111%22%3E%3Cvideo%20id%3D%22v%22%20autoplay%20loop%20playsinline%20style%3D%22width%3A100%25%22%20src%3D%22https%3A//interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4%22%3E%3C/video%3E")!)
    var state: [String: Any] = [:]
    spin(30) {
        videoTab.webView?.evaluateJavaScript("(function(){var v=document.getElementById('v');return v?{ready:v.readyState,paused:v.paused,time:v.currentTime,pip:!!(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture'))}:{};})()") { value, _ in
            state = value as? [String: Any] ?? [:]
        }
        return (state["time"] as? Double ?? 0) > 0.2
    }
    check("a video with sound starts without being clicked", state["paused"] as? Bool == false && (state["time"] as? Double ?? 0) > 0.2)
    check("WebKit offers picture in picture for it", state["pip"] as? Bool == true)
    // Playing is not the same as being heard: ask the page about its sound, and
    // WebKit whether audio is actually coming out of this web view.
    let sound = ask(videoTab, "(function(){var v=document.getElementById('v'); var tracks = v.audioTracks ? v.audioTracks.length : -1; return JSON.stringify({muted: v.muted, volume: v.volume, audioTracks: tracks, hasAudio: (typeof v.webkitAudioDecodedByteCount === 'number') ? v.webkitAudioDecodedByteCount : 'n/a'});})()")
    var audible: Bool?
    spin(6) {
        if let view = videoTab.webView, view.responds(to: Selector(("_isPlayingAudio"))) {
            audible = view.value(forKey: "_isPlayingAudio") as? Bool
        }
        return audible == true
    }
    print("       page says: \(sound)")
    check("the video's sound is really being played, not just its picture", audible == true)
    spin(4) { videoTab.hasVideo }
    check("the tab notices it has a video, which shows the button", videoTab.hasVideo)
    check("a page without one does not", !first.hasVideo)
    // Whether picture in picture can really open is a question for a window on
    // a screen. What can be asked here is what the script decides to do.
    var decision = ""
    videoTab.pictureInPicture(.tabShown) { decision = $0 }
    spin(5) { !decision.isEmpty }
    check("coming back to a video that never left does nothing", decision == "none")
    decision = ""
    videoTab.pictureInPicture(.tabHidden) { decision = $0 }
    spin(5) { !decision.isEmpty }
    check("leaving a playing video with sound pops it out", decision == "entered")
    print("       decision: \(decision)")
    // The picture-in-picture window's arrow: WebKit asks the browser, through
    // a private delegate call, to show the page, and only then puts the video
    // back. Its × pauses the video and asks for nothing.
    store.select(first)
    check("another tab is in front", store.focused === first)
    if let view = videoTab.webView { videoTab.webViewFullscreenMayReturnToInline(view) }
    spin(3) { store.focused === videoTab }
    check("the arrow brings the video's tab back in front", store.focused === videoTab)
    check("WebKit can find the arrow's answer on the tab", (videoTab as AnyObject).responds(to: Selector(("_webViewFullscreenMayReturnToInline:"))))
    store.select(first)
    var closed = ""
    videoTab.webView?.evaluateJavaScript("(function(){var v=document.getElementById('v'); v.pause(); window.__driftPiPWas='picture-in-picture'; window.__driftPiPByUs=false; v.dispatchEvent(new Event('webkitpresentationmodechanged')); return 'ok'; })()", in: nil, in: Tab.ownWorld) { result in closed = ((try? result.get()) as? String) ?? "?" }
    spin(5) { !closed.isEmpty }
    spin(1.5)
    check("the × leaves the other tab in front", store.focused === first)
    _ = ask(videoTab, "(function(){var v=document.getElementById('v'); if (v.webkitPresentationMode==='picture-in-picture') { window.__driftPiPByUs = true; v.webkitSetPresentationMode('inline'); } v.play(); return 'ok';})()")
    var muted = ""
    videoTab.webView?.evaluateJavaScript("(function(){var v=document.getElementById('v'); if (v.webkitPresentationMode==='picture-in-picture') v.webkitSetPresentationMode('inline'); v.muted=true; return 'ok';})()") { _, _ in muted = "ok" }
    spin(5) { !muted.isEmpty }
    decision = ""
    videoTab.pictureInPicture(.tabHidden) { decision = $0 }
    spin(5) { !decision.isEmpty }
    check("a muted one is left where it is", decision == "none")
    store.close(videoTab)
    }

    print("site quirks")
    // Microsoft covers its empty inputs with a <div> of hint text, which makes
    // password managers think the field is hidden and refuse to fill it.
    let signIn = store.newTab(URL(string: "https://login.microsoftonline.com/")!)
    var topmost = ""
    spin(40) {
        signIn.webView?.evaluateJavaScript("(function(){var i=document.querySelector('input[name=loginfmt]'); if(!i) return ''; var r=i.getBoundingClientRect(); if (r.width < 10) return ''; var hit=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2); return hit===i ? 'input' : (hit ? hit.tagName+'.'+hit.className : 'nothing');})()") { value, _ in
            topmost = value as? String ?? ""
        }
        return topmost == "input"
    }
    check("on Microsoft's sign-in the email field is what is under the pointer", topmost == "input")
    if topmost != "input" { print("       found: \(topmost.isEmpty ? "(page did not load a sign-in form)" : topmost)") }
    store.close(signIn)

    print("ad blocking")
    spin(15) { AdBlock.shared.ruleList != nil }
    check("the block list compiled", AdBlock.shared.ruleList != nil)
    print("       \(AdBlock.shared.hostCount) hosts")

    // Needs the archives in .build/fixtures, which are downloads and not part
    // of the project; without them this part is skipped.
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fixtures")
    let blocker = fixtures.appendingPathComponent("ubol.zip")
    if FileManager.default.fileExists(atPath: blocker.path) {
        print("extensions")
        let extensions = Extensions.shared

        @MainActor func finish(_ work: @escaping @MainActor () async -> Void) {
            var done = false
            Task { @MainActor in await work(); done = true }
            spin(60) { done }
        }
        @MainActor func adRequest(in tab: Tab) -> String {
            var answer = ""
            let script = "return await fetch('https://ads.pubmatic.com/AdServer/js/pwt.js', {mode: 'no-cors'}).then(function () { return 'loaded'; }).catch(function () { return 'blocked'; });"
            tab.webView?.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                answer = (try? result.get()) as? String ?? "error"
            }
            spin(15) { !answer.isEmpty }
            return answer
        }

        // Drift's own blocker off, so what is measured is the extension's.
        AdBlock.shared.enabled = false
        let probe = store.newTab(URL(string: "https://example.org/")!)
        spin(20) { !probe.isLoading && !probe.title.isEmpty }
        check("with no blocker at all, an ad request goes through", adRequest(in: probe) == "loaded")

        finish { try? await extensions.install(from: blocker, source: nil, confirm: false) }
        check("uBlock Origin Lite installs from its zip", extensions.installed.count == 1)
        let ubol = extensions.installed.first
        check("and loads under its own name", ubol.map(extensions.name(of:)) == "uBlock Origin Lite")
        check("it gets a toolbar button with a popup",
              extensions.actionable.count == 1 && ubol.flatMap { extensions.context($0.id) }?.action(for: probe)?.presentsPopup == true)
        check("extensions are told about the tabs", ubol.flatMap { extensions.context($0.id) }?.openTabs.count == store.tabs.count)
        var verdict = ""
        spin(40) { verdict = adRequest(in: probe); return verdict == "blocked" }
        check("and then the same ad request is blocked", verdict == "blocked")

        // A page's script must be able to reach its extension's background page
        // and be known there as a tab. When it could not, BetterCampus took it
        // for having no settings and crashed.
        let probeFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/probe")
        finish { try? await extensions.install(from: probeFixture, source: nil, confirm: false) }
        let probeRecord = extensions.installed.last
        @MainActor func whoAmI(_ tab: Tab) -> String {
            var answer = ""
            spin(12) {
                tab.webView?.evaluateJavaScript("document.documentElement.getAttribute('data-drift-probe') || ''") { value, _ in answer = value as? String ?? "" }
                return !answer.isEmpty
            }
            return answer
        }
        let asked = store.newTab(URL(string: "https://example.net/")!)
        spin(20) { !asked.isLoading && !asked.title.isEmpty }
        let fresh = whoAmI(asked)
        check("a new page's script reaches the background and is known as a tab", fresh.hasPrefix("tab:"))
        check("a newly installed extension is told it was installed", fresh.contains("installed:update") || fresh.contains("installed:install"))
        if !fresh.hasPrefix("tab:") { print("       got: \(fresh.isEmpty ? "(no answer)" : fresh)") }
        // `probe` was open before this extension existed, which is the position
        // every restored tab is in at launch.
        probe.reload()
        spin(1)
        spin(20) { !probe.isLoading }
        let older = whoAmI(probe)
        check("so does a tab that was open before the extension loaded", older.hasPrefix("tab:"))
        if !older.hasPrefix("tab:") { print("       got: \(older.isEmpty ? "(no answer)" : older)") }
        store.close(asked)

        // Private windows: an extension is kept out until let in, and then
        // only that one sees and runs in private tabs.
        if let probeRecord, let ubol {
            let secret = PrivateSession.shared.begin()
            let secretPanel = show(secret)
            let shut = secret.newTab(URL(string: "https://example.com/")!)
            spin(20) { !shut.isLoading && !shut.title.isEmpty }
            check("with no extension let in, a private tab has no extensions attached", shut.webView?.configuration.webExtensionController == nil)
            extensions.setAllowedInPrivate(probeRecord, true)
            check("letting one in is remembered on disk", Storage.load([InstalledExtension].self, from: "extensions.json")?.first { $0.id == probeRecord.id }?.allowedInPrivate == true)
            let open = secret.newTab(URL(string: "https://example.com/")!)
            spin(20) { !open.isLoading && !open.title.isEmpty }
            check("then a new private tab is attached", open.webView?.configuration.webExtensionController != nil)
            check("and the extension let in runs there", whoAmI(open).hasPrefix("tab:"))
            // A second copy of the probe, kept out, must not run in that same
            // tab: WebKit's per-extension hiding, checked on a page.
            let twin = FileManager.default.temporaryDirectory.appendingPathComponent("drift-probe-twin-\(getpid())", isDirectory: true)
            try? FileManager.default.removeItem(at: twin)
            try? FileManager.default.copyItem(at: probeFixture, to: twin)
            for name in ["manifest.json", "content.js"] {
                let file = twin.appendingPathComponent(name)
                if var text = try? String(contentsOf: file, encoding: .utf8) {
                    text = text.replacingOccurrences(of: "Drift Probe", with: "Drift Probe Twin").replacingOccurrences(of: "data-drift-probe", with: "data-drift-probe-twin")
                    try? text.write(to: file, atomically: true, encoding: .utf8)
                }
            }
            finish { try? await extensions.install(from: twin, source: nil, confirm: false) }
            let twinRecord = extensions.installed.last
            check("a second copy of the probe installs alongside", twinRecord != nil && twinRecord?.id != probeRecord.id)
            let watched = secret.newTab(URL(string: "https://example.net/")!)
            spin(20) { !watched.isLoading && !watched.title.isEmpty }
            check("the extension let in runs in the next private tab too", whoAmI(watched).hasPrefix("tab:"))
            spin(2)
            var twinMark = "?"
            watched.webView?.evaluateJavaScript("document.documentElement.getAttribute('data-drift-probe-twin') || ''") { value, _ in twinMark = value as? String ?? "?" }
            spin(3) { twinMark != "?" }
            check("while the copy kept out does not run there", twinMark.isEmpty)
            let ordinary = store.newTab(URL(string: "https://example.net/")!)
            spin(20) { !ordinary.isLoading && !ordinary.title.isEmpty }
            spin(2)
            var twinOrdinary = "?"
            ordinary.webView?.evaluateJavaScript("document.documentElement.getAttribute('data-drift-probe-twin') || ''") { value, _ in twinOrdinary = value as? String ?? "?" }
            spin(3) { twinOrdinary != "?" }
            check("though it still runs in an ordinary tab", twinOrdinary.hasPrefix("tab:"))
            store.close(ordinary)
            if let twinRecord { extensions.remove(twinRecord) }
            try? FileManager.default.removeItem(at: twin)
            extensions.setAllowedInPrivate(probeRecord, false)
            let shutAgain = secret.newTab(URL(string: "https://example.com/")!)
            spin(20) { !shutAgain.isLoading && !shutAgain.title.isEmpty }
            check("kept out again, the next private tab has no extensions", shutAgain.webView?.configuration.webExtensionController == nil)
            secretPanel.orderOut(nil)
            PrivateSession.shared.end()
            spin(0.5)
            check("closing the private window leaves the main window's tabs to extensions", extensions.context(probeRecord.id)?.openTabs.count == store.tabs.count)
        }

        // Confined to one host, it must keep working there and stay out of
        // everywhere else, without WebKit asking the user about the rest.
        if let probeRecord {
            check("an extension that asked for every site can be confined", extensions.asksForEverySite(probeRecord))
            extensions.setSites(probeRecord, ["example.com"])
            check("the limit is remembered on disk", Storage.load([InstalledExtension].self, from: "extensions.json")?.first { $0.id == probeRecord.id }?.sites == ["example.com"])
            let allowed = store.newTab(URL(string: "https://example.com/")!)
            spin(20) { !allowed.isLoading && !allowed.title.isEmpty }
            check("confined to example.com, it still runs there", whoAmI(allowed).hasPrefix("tab:"))
            let elsewhere = store.newTab(URL(string: "https://example.net/")!)
            spin(20) { !elsewhere.isLoading && !elsewhere.title.isEmpty }
            spin(2)
            var stray = "?"
            elsewhere.webView?.evaluateJavaScript("document.documentElement.getAttribute('data-drift-probe') || ''") { value, _ in stray = value as? String ?? "?" }
            spin(3) { stray != "?" }
            check("and no longer touches other sites", stray.isEmpty)
            extensions.setSites(probeRecord, nil)
            let again = store.newTab(URL(string: "https://example.net/")!)
            spin(20) { !again.isLoading && !again.title.isEmpty }
            check("lifting the limit lets it back in", whoAmI(again).hasPrefix("tab:"))
            [allowed, elsewhere, again].forEach(store.close)
        }
        if let probeRecord { extensions.remove(probeRecord) }

        // Cmd-W with a popup open should close the popup, not the tab under it.
        check("with no popup open there is nothing to close", !extensions.closeOpenPopup())
        if let ubol { extensions.perform(ubol) }
        var closedPopup = false
        spin(6) { closedPopup = extensions.closeOpenPopup(); return closedPopup }
        let tabsBefore = store.tabs.count
        check("an open extension popup is what gets closed", closedPopup)
        check("and only once, leaving the tabs alone", !extensions.closeOpenPopup() && store.tabs.count == tabsBefore)

        finish { try? await extensions.install(from: fixtures.appendingPathComponent("bettercampus.crx"), source: nil, confirm: false) }
        let campus = extensions.installed.last
        check("a .crx from the Chrome Web Store unpacks and loads",
              extensions.installed.count == 2 && campus.map(extensions.name(of:))?.hasPrefix("BetterCampus") == true)
        check("it injects into pages", campus.flatMap { extensions.context($0.id) }?.hasInjectedContent == true)
        // It writes its default settings when told it was installed, and its
        // page component crashes without them. WebKit never sends that event
        // for a first install outside Safari; Drift arranges it.
        var defaults = ""
        if let view = campus.flatMap({ extensions.context($0.id) })?.value(forKey: "_backgroundWebView") as? WKWebView {
            spin(40) {
                view.callAsyncJavaScript("var all = await chrome.storage.local.get(null); return Object.keys(all).length + ' ' + ('sidebar_collapsed_sections' in all);", arguments: [:], in: nil, in: .page) { result in
                    defaults = (try? result.get()) as? String ?? ""
                }
                return defaults.hasSuffix("true")
            }
        }
        check("BetterCampus sets itself up: its default settings get written", defaults.hasSuffix("true"))
        print("       settings stored, and whether the one it crashed on is among them: \(defaults.isEmpty ? "(no answer)" : defaults)")

        finish { try? await extensions.install(from: fixtures.appendingPathComponent("bitwarden.zip"), source: nil, confirm: false) }
        let vault = extensions.installed.last
        check("Bitwarden loads, with a popup and page scripts",
              extensions.installed.count == 3
              && vault.flatMap { extensions.context($0.id) }?.action(for: nil)?.presentsPopup == true
              && vault.flatMap { extensions.context($0.id) }?.hasInjectedContent == true)
        // Extensions vet their own addresses against the schemes they know, and
        // WebKit's default is not one of them. Bitwarden's in-field menu came
        // out as an empty sliver because of it.
        let known = ["chrome-extension", "moz-extension", "safari-web-extension"]
        check("every extension is served under a scheme extensions recognise",
              extensions.installed.allSatisfy { record in
                  extensions.context(record.id).map { known.contains($0.baseURL.scheme ?? "") } ?? false
              })

        // Loading is not the same as working: the popup is an app of its own
        // and once sat on its spinner for ever, having crashed on a user agent
        // it did not recognise.
        if let popup = vault.flatMap({ extensions.context($0.id) })?.action(for: nil)?.popupWebView {
            popup.frame = CGRect(x: 0, y: 0, width: 380, height: 600)
            host.addSubview(popup)
            var rendered = ""
            spin(30) {
                popup.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in rendered = value as? String ?? "" }
                return rendered.count > 40
            }
            check("Bitwarden's popup gets as far as its welcome screen", rendered.count > 40)
            print("       \(rendered.split(separator: "\n").first.map(String.init) ?? "(blank)")")
            popup.removeFromSuperview()
        }
        spin(1)
        shot("extensions")

        finish { try? await extensions.install(from: blocker, source: nil, confirm: false) }
        check("installing the same extension again updates it in place",
              extensions.installed.count == 3 && extensions.installed.first?.id == ubol?.id)

        if let campus { extensions.setEnabled(campus, false) }
        check("switching one off unloads it and keeps it listed",
              extensions.installed.count == 3 && campus.flatMap { extensions.context($0.id) } == nil)
        if let campus { extensions.remove(campus) }
        check("removing one forgets it", extensions.installed.count == 2)
        check("extension errors so far: none", extensions.lastError == nil)
        if let error = extensions.lastError { print("       \(error)") }

        AdBlock.shared.enabled = true
        store.close(probe)
    } else {
        print("extensions: skipped, no fixtures")
    }

    print("dark google docs")
    // A public Chromium design doc with a photo near the top. Off screen
    // nothing is painted, but the styles that decide the look can be read.
    let docs = store.newTab(URL(string: "https://docs.google.com/document/d/1cSW8fpJIUnibQKU8TMwLE5VxYZPh4u4LNu_wtkok8UE/edit")!)
    spin(0.5)
    docs.webView?.appearance = NSAppearance(named: .darkAqua)
    let pictureLayer = "canvas.kix-canvas-tile-content ~ .kix-canvas-tile-content > svg"
    spin(30) { !docs.isLoading && ask(docs, "document.querySelector('\(pictureLayer)') ? 'yes' : 'no'") == "yes" }
    @MainActor func docsLook() -> String {
        ask(docs, "getComputedStyle(document.documentElement).filter + ' | ' + getComputedStyle(document.querySelector('\(pictureLayer)')).filter")
    }
    check("in dark mode a document is inverted, with its hue kept",
          docsLook().hasPrefix("invert(1) hue-rotate(180deg) |"))
    check("and the layer its pictures are drawn in is turned back", docsLook().hasSuffix("| invert(1) hue-rotate(180deg)"))
    docs.sampleTint()
    spin(3) { docs.tint?.wantsLightText == true }
    check("the top colour follows it into the dark", docs.tint?.wantsLightText == true)
    docs.setDocsDark(false)
    spin(0.5)
    check("the View menu switch turns it off in an open tab", docsLook() == "none | none")
    docs.setDocsDark(true)
    spin(0.5)
    check("and on again", docsLook().hasPrefix("invert(1) hue-rotate(180deg) |"))
    docs.webView?.appearance = NSAppearance(named: .aqua)
    spin(0.5)
    check("in light mode the document is left as it is", docsLook() == "none | none")
    store.close(docs)

    print("chrome web store")
    // The store greys out "Add to Chrome" outside Chrome; Drift makes it its own.
    let ubolID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    let storePage = store.newTab(URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(ubolID)")!)
    let storeButtons = "JSON.stringify(Array.prototype.map.call(document.querySelectorAll('button[data-drift-store]'), function (b) { return b.textContent.trim() + (b.disabled ? ' (disabled)' : ''); }))"
    spin(40) { !storePage.isLoading && ask(storePage, storeButtons).contains("Drift") }
    let expected = Extensions.shared.installed(storeID: ubolID, name: "uBlock Origin Lite") == nil ? "Add to Drift" : "Remove from Drift"
    let shown = ask(storePage, storeButtons)
    print("       \(shown)")
    check("the store's greyed-out install button becomes \u{201c}\(expected)\u{201d}, and can be clicked",
          shown.contains(expected) && !shown.contains("(disabled)"))
    check("the store's \u{201c}Switch to Chrome to install\u{201d} strip is put away",
          ask(storePage, "(function () { var w = document.createTreeWalker(document.querySelector('main') || document.body, NodeFilter.SHOW_TEXT); for (var n = w.nextNode(); n; n = w.nextNode()) { if (/Switch to Chrome to install/.test(n.nodeValue)) return n.parentElement.getClientRects().length ? 'shown' : 'hidden'; } return 'absent'; })()") != "shown")
    store.close(storePage)

    print("tab groups")
    do {
        // A tab of its own, behind, so the one in front stays as it was.
        let grouped = store.newTab(URL(string: "data:text/html,%3Ctitle%3EGrouped%3C/title%3EGrouped")!, inBackground: true)
        spin(1)
        let group = store.newGroup(named: "Smoke group", with: grouped)
        store.setCollapsed(group.id, true)
        store.advanceSwitcher(backwards: false)
        check("a collapsed group is one stacked card in Ctrl-Tab",
              store.switcher.map { $0.entries.contains(.group(group.id)) && !$0.entries.contains(.tab(grouped.id)) } == true)
        store.cancelSwitcher()
        store.saveNow()
        let file = (try? String(contentsOf: Storage.directory.appendingPathComponent("session.json"), encoding: .utf8)) ?? ""
        check("groups are saved with the session", file.contains("Smoke group"))
        store.ungroup(group.id)
        check("ungrouping keeps the tab and drops the group", store.tab(grouped.id) != nil && store.groups.isEmpty && grouped.groupID == nil)
        store.close(grouped)
    }

    print("session")
    store.saveNow()
    let saved = (try? Data(contentsOf: Storage.directory.appendingPathComponent("session.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    // Not a fixed number: extensions open welcome pages of their own on install.
    check("the session file lists every open tab",
          store.tabs.count >= 2 && (saved?["tabs"] as? [[String: Any]])?.count == store.tabs.count)
    for tab in store.tabs { print("       tab: \(tab.url?.absoluteString.prefix(90) ?? "-")") }
    check("it is in the scratch folder, not the real profile", Storage.directory.path.contains("drift-smoke"))
}

print(failures == 0 ? "\nsmoke test passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
