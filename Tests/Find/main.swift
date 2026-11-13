import AppKit
import WebKit
import SwiftUI

var failures = 0
func check(_ title: String, _ pass: Bool) {
    print("\(pass ? "ok" : "FAIL") \(title)")
    if !pass { failures += 1 }
}
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let store = BrowserStore.shared
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    window.contentView = host
    window.orderBack(nil)
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    var ready = false
    Task { await Extensions.shared.start(); ready = true }
    spin(10) { ready }
    let tab = store.newTab(URL(string: "about:blank")!)
    spin(0.2)
    tab.materialize().loadHTMLString("<html><head><title>Find fixture</title></head><body><p>Alpha one</p><p>Alpha two</p><p>alpha three</p><iframe srcdoc=\"<p>InsideFrame</p>\"></iframe></body></html>", baseURL: nil)
    spin(5) { !tab.isLoading && tab.title == "Find fixture" }
    check("fixture loads", tab.title == "Find fixture")
    store.showFind()
    spin(0.3)
    let finder = tab.finder
    finder.query = "alpha"
    spin(3) { finder.result == .found }
    check("typing performs a case-insensitive search", finder.result == .found)
    @MainActor func selectedParagraph() -> String {
        var answer: String?
        tab.webView?.evaluateJavaScript("window.getSelection()?.anchorNode?.parentElement?.textContent ?? ''") { result, _ in answer = result as? String ?? "" }
        spin(2) { answer != nil }
        return answer ?? ""
    }
    check("first match is selected", selectedParagraph() == "Alpha one")
    check("typing keeps focus in the find field", window.firstResponder is NSTextView)
    finder.next()
    spin(2) { finder.result == .found }
    check("next match advances the selection", finder.result == .found && selectedParagraph() == "Alpha two")
    finder.next(backwards: true)
    spin(2) { finder.result == .found }
    check("previous match moves back", finder.result == .found && selectedParagraph() == "Alpha one")
    finder.next(backwards: true)
    spin(2) { finder.result == .found }
    check("previous wraps to the last match", selectedParagraph() == "alpha three")
    finder.next()
    spin(2) { finder.result == .found }
    check("next wraps to the first match", selectedParagraph() == "Alpha one")
    finder.query = "not-present"
    spin(3) { finder.result == .missing }
    check("a miss is reported", finder.result == .missing)
    finder.query = "InsideFrame"
    spin(3) { finder.result == .found }
    check("native search finds text inside an iframe", finder.result == .found)
    finder.caseSensitive = true
    finder.query = "ALPHA"
    spin(3) { finder.result == .missing }
    check("match case is respected", finder.result == .missing)
    finder.caseSensitive = false
    spin(3) { finder.result == .found }
    check("turning match case off searches again", finder.result == .found)
    finder.query = "Alpha"
    finder.query = "zzz"
    finder.query = "InsideFrame"
    spin(3) { finder.result == .found }
    check("rapid query edits use the latest query", finder.query == "InsideFrame" && finder.result == .found)
    finder.query = ""
    spin(0.4)
    check("clearing the query resets feedback", finder.result == .idle)
    finder.query = "Alpha"
    spin(3) { finder.result == .found }
    store.dismissFind()
    spin(0.3)
    check("dismissing resets find feedback", finder.result == .idle)
    check("dismissing returns focus to the page", window.firstResponder === tab.webView)
    check("dismissing preserves the query for reopening", finder.query == "Alpha" && !store.findVisible)
    store.showFind()
    spin(2) { finder.result == .found }
    check("reopening repeats the saved search", finder.result == .found)
    finder.query = "not-present"
    store.dismissFind()
    spin(0.4)
    check("dismissing cancels a pending search", finder.result == .idle)
    finder.query = "Alpha"
    store.showFind()
    spin(2) { finder.result == .found }
    host.layoutSubtreeIfNeeded()
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    finder.query = "Alpha"
    tab.sleep()
    spin(0.4)
    check("a discarded view cannot publish a late result", finder.result == .idle)
    store.close(tab)
}
print(failures == 0 ? "find tests passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
