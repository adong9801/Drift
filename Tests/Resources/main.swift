import AppKit
import SwiftUI
import WebKit

var failures = 0
func check(_ title: String, _ passed: Bool) {
    print("\(passed ? "ok" : "FAIL") \(title)")
    if !passed { failures += 1 }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let settings = ["drift.memoryBudgetMB.v1", "drift.sleepTabs.v1", "drift.sleepMinutes.v1"]
    let previous = settings.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    defer {
        for (key, value) in previous {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    let store = BrowserStore.shared
    let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 1100, height: 750), styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    window.contentView = host
    window.orderBack(nil)
    var ready = false
    Task { await Extensions.shared.start(); ready = true }
    spin(10) { ready }
    check("extensions are ready", ready)

    @MainActor func page(_ title: String, body: String = "<textarea id='draft'></textarea>") -> Tab {
        let tab = store.newTab(URL(string: "about:blank")!)
        spin(0.2)
        tab.materialize().loadHTMLString("<html><head><title>\(title)</title></head><body>\(body)</body></html>", baseURL: nil)
        spin(8) { !tab.isLoading && tab.title == title }
        check("\(title) loaded", tab.title == title)
        return tab
    }
    @MainActor func js(_ tab: Tab, _ script: String, world: WKContentWorld = .page) -> Any? {
        var answered = false
        var value: Any?
        tab.webView?.evaluateJavaScript(script, in: nil, in: world) { result in
            value = try? result.get()
            answered = true
        }
        spin(4) { answered }
        return value
    }
    @MainActor func activity(_ tab: Tab) -> TabSleep.Activity {
        var answer: TabSleep.Activity?
        tab.activity { answer = $0 }
        spin(3) { answer != nil }
        return answer ?? .init(unknown: true)
    }

    let first = page("Oldest")
    let second = page("Recent")
    let visible = page("Visible")
    check("quiet document can be measured safely", activity(first) == TabSleep.Activity())
    let memory = MemoryMonitor.shared
    memory.limitMB = 0
    memory.refresh()
    check("process footprint is available", (memory.usedBytes ?? 0) > 0)
    check("WebKit processes are included", memory.processCount >= 3)
    print("baseline: \(memory.usedBytes ?? 0) bytes in \(memory.processCount) processes, partial=\(memory.incomplete)")
    // Ask for actual committed memory in a page, rather than a mock meter.
    _ = js(first, "globalThis.payload = new Uint8Array(100 * 1024 * 1024); for (var i=0;i<payload.length;i+=4096) payload[i]=123; payload.length")
    memory.refresh()
    let before = memory.usedBytes ?? 0
    first.lastActive = Date().addingTimeInterval(-120)
    second.lastActive = Date().addingTimeInterval(-60)
    // A tiny test limit makes selection deterministic on any machine.
    memory.limitMB = 1
    spin(3) { first.isAsleep }
    check("budget sleeps the oldest eligible tab first", first.isAsleep && !second.isAsleep)
    check("visible tab stays awake above budget", !visible.isAsleep)
    spin(4)
    memory.limitMB = 0
    memory.refresh()
    let after = memory.usedBytes ?? 0
    check("releasing the tab lowers measured memory", after < before)
    print("budget: before=\(before) after=\(after) reclaimed=\(Int64(before) - Int64(after)) bytes")
    spin(0.2)
    check("turning off the budget stops reclamation", !second.isAsleep)

    // Simulate an edited document inside the isolated world. Page scripts
    // cannot set these variables in Drift's world.
    _ = js(second, "globalThis.__driftEdited = true", world: Tab.ownWorld)
    check("edited document is protected", activity(second).edited)
    store.sleepIdleTabs(olderThan: 0, force: true)
    spin(0.3)
    check("manual sleep preserves a draft", !second.isAsleep)
    _ = js(second, "globalThis.__driftTracked = false", world: Tab.ownWorld)
    check("missing tracker fails closed", activity(second).unknown)

    let framed = page("Frame draft", body: "<iframe srcdoc=\"<textarea>work</textarea>\"></iframe>")
    // Every frame has the isolated tracker. This fixture adds a script in the
    // same world to emulate a trusted user edit in the child document.
    let fixture = WKUserScript(source: "if (self !== top) { globalThis.__driftEdited = true; webkit.messageHandlers.driftActivity.postMessage({frame:'test-child',edited:true,playing:false}); }", injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Tab.ownWorld)
    framed.webView?.configuration.userContentController.addUserScript(fixture)
    framed.webView?.loadHTMLString("<html><head><title>Frame draft fixture</title></head><body><iframe srcdoc=\"<textarea>work</textarea>\"></iframe></body></html>", baseURL: nil)
    spin(2)
    print("frame count: \(js(framed, "window.frames.length") ?? "unknown"), activity: \(activity(framed))")
    check("a draft inside a child frame protects its tab", activity(framed).edited)
    store.select(visible)
    spin(0.2)
    store.sleepIdleTabs(olderThan: 0, force: true)
    spin(0.3)
    check("frame draft survives background tab sleeping", !framed.isAsleep)

    let quiet = page("Terminated")
    store.select(visible)
    spin(0.2)
    if let view = quiet.webView { quiet.webViewWebContentProcessDidTerminate(view) }
    check("terminated background page stays asleep", quiet.isAsleep)
    store.select(first)
    spin(5) { first.webView != nil && !first.isLoading }
    check("selecting a sleeping tab restores a web view", first.isLive)

    // The activity callback arrives asynchronously: choosing a candidate or
    // raising the budget before it returns must cancel that discard.
    _ = js(second, "globalThis.__driftTracked = true; globalThis.__driftEdited = false", world: Tab.ownWorld)
    second.lastActive = Date().addingTimeInterval(-120)
    memory.limitMB = 1
    store.select(second)
    spin(0.5)
    check("selecting a candidate cancels its pending discard", !second.isAsleep)
    memory.limitMB = 0
    store.select(first)
    second.lastActive = Date().addingTimeInterval(-120)
    memory.limitMB = 1
    memory.limitMB = 8192
    spin(0.5)
    check("raising the budget cancels a pending discard", !second.isAsleep)
    memory.limitMB = 0

    let icon = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let icons = Storage.directory.appendingPathComponent("favicons")
    try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
    try? icon.representation(using: .png, properties: [:])?.write(to: icons.appendingPathComponent("large-icon.invalid"))
    let smallIcon = FaviconCache.shared.cached(host: "large-icon.invalid")
    check("large cached icons are downsampled to 64 pixels", smallIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 64)
    FaviconCache.shared.trim()
    check("evicted icons remain available from disk", FaviconCache.shared.cached(host: "large-icon.invalid") != nil)

    // History should be unchanged after switching tabs and saving the session.
    store.recordVisit(url: URL(string: "https://drift.invalid/test")!, title: "Local test")
    store.saveNow()
    let history = Storage.directory.appendingPathComponent("history.json")
    let stamp = (try? history.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    spin(1.1)
    store.select(visible)
    store.saveNow()
    check("tab switches do not rewrite history", stamp == (try? history.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)

    let settingsHost = NSHostingView(rootView: PerformanceSettings())
    window.setContentSize(NSSize(width: 520, height: 560))
    settingsHost.frame = CGRect(x: 0, y: 0, width: 520, height: 560)
    window.contentView = settingsHost
    settingsHost.layoutSubtreeIfNeeded()
    if let bitmap = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds) {
        settingsHost.cacheDisplay(in: settingsHost.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    for tab in store.tabs { store.close(tab) }
    memory.limitMB = 0
}
print(failures == 0 ? "resource tests passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
