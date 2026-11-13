import AppKit
import WebKit

/// Everything worth knowing about a bug, zipped onto the Desktop: what was
/// open and in what state, what each page complained about, pictures of the
/// windows and pages, the extension log, and what Drift's own processes wrote
/// to the system log in the last few minutes.
///
/// It carries page addresses and titles, which is the point, and never cookies,
/// passwords, form contents or page text. The prompt says as much.
@MainActor
enum DebugArchive {

    /// How far back the system log is read. Long enough to cover "it just
    /// happened", short enough that reading it does not take an age.
    static let logWindow = "5m"

    static func create(note: String) async throws -> URL {
        let stamp = Self.stamp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Drift-debug-\(stamp)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(note.isEmpty ? "(nothing written)" : note, to: root, "what-happened.txt")
        try write(await report(), to: root, "report.txt")
        try write(await Extensions.shared.diagnostics(), to: root, "extensions.txt")
        for name in ["extensions.log", "extensions.json", "session.json"] {
            let source = Storage.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
            }
        }

        let pages = root.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        var number = 0
        for store in BrowserStore.all {
            for tab in store.tabs {
                number += 1
                let stem = String(format: "%02d-%@", number, Self.slug(tab.url?.host ?? "new-tab"))
                var text = "\(tab.url?.absoluteString ?? "no address")\n\(tab.title)\n"
                if let view = tab.webView, view.window != nil, !tab.isAsleep {
                    text += "page says: \(await pageMetrics(view))\n"
                }
                text += "\n"
                text += tab.log.render()
                try write(text, to: pages, stem + ".txt")
                // Only a page on screen can be photographed; WebKit does not
                // paint the others.
                if let view = tab.webView, view.window != nil, !tab.isAsleep, let image = await snapshot(view) {
                    try? image.write(to: pages.appendingPathComponent(stem + ".png"))
                }
            }
        }

        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            if let image = chrome(of: window) {
                try? image.write(to: root.appendingPathComponent("window-\(index + 1).png"))
            }
        }

        try write(await systemLog(), to: root, "system.log")

        let zip = Self.destination(stamp)
        try? FileManager.default.removeItem(at: zip)
        try await Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path, zip.path], timeout: 60)
        try? FileManager.default.removeItem(at: root)
        return zip
    }

    // MARK: - The report

    private static func report() async -> String {
        var lines: [String] = []
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        lines.append("Drift \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")) at \(bundle.bundlePath)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.machine())")
        lines.append("made \(Date().formatted(date: .abbreviated, time: .standard)), running for \(Self.runningFor())")
        lines.append("sleep tabs: \(TabSleep.enabled ? "on, idle after \(Int(TabSleep.idleLimit / 60)) min" : "off")")
        lines.append("ad blocking: \(AdBlock.shared.enabled ? "on, \(AdBlock.shared.hostCount) hosts" : "off")")
        lines.append("picture in picture when leaving a page: \(PictureInPicture.automatic ? "on" : "off")")

        lines.append("app active: \(NSApp.isActive)")
        lines.append("\n== Windows")
        for window in NSApp.windows where window.isVisible {
            var flags: [String] = []
            if window.isKeyWindow { flags.append("key") }
            if window.isMainWindow { flags.append("main") }
            if window.styleMask.contains(.fullScreen) { flags.append("full screen") }
            let store = BrowserStore.store(for: window).map { $0.isPrivateWindow ? "private store" : "main store" } ?? "no store"
            if !window.occlusionState.contains(.visible) { flags.append("OCCLUDED: macOS says something covers it") }
            if !window.isOnActiveSpace { flags.append("on another Space") }
            let screen = window.screen.map { "\($0.localizedName) \(Int($0.frame.width))×\(Int($0.frame.height)) at \($0.backingScaleFactor)x" } ?? "no screen"
            lines.append("\(window.className) \"\(window.title)\" \(Int(window.frame.width))×\(Int(window.frame.height)) [\(flags.joined(separator: ", "))] \(store), responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"), on \(screen)")
        }

        for store in BrowserStore.all {
            lines.append("\n== \(store.isPrivateWindow ? "Private window" : "Main window")")
            lines.append("sidebar \(store.sidebarVisible ? "shown" : "hidden"), split \(store.split == nil ? "off" : "on, focused pane \(store.focusedPane)"), full screen \(store.isFullScreen), command bar \(store.commandBar == nil ? "closed" : "open"), switcher \(store.switcher == nil ? "closed" : "open")")
            for tab in store.tabs {
                var marks: [String] = []
                if tab.id == store.selectedID { marks.append("selected") }
                if tab.id == store.split?.id { marks.append("split") }
                if tab.isPinned { marks.append("pinned") }
                if tab.isAsleep { marks.append("asleep") }
                if tab.isLoading { marks.append("loading") }
                if tab.hasVideo { marks.append("video") }
                if let view = tab.webView {
                    switch view.fullscreenState {
                    case .inFullscreen: marks.append("page full screen")
                    case .enteringFullscreen: marks.append("entering full screen")
                    case .exitingFullscreen: marks.append("leaving full screen")
                    default: break
                    }
                    marks.append(view.window == nil ? "off screen" : "in \(view.window === store.window ? "its window" : "another window")")
                    if view.responds(to: Selector(("_isPlayingAudio"))), (view.value(forKey: "_isPlayingAudio") as? Bool) == true { marks.append("playing audio") }
                    marks.append("drawn at \(view.window?.backingScaleFactor ?? 0)x, zoom \(view.pageZoom), magnification \(view.magnification)")
                }
                lines.append("- [\(marks.joined(separator: ", "))] \(tab.url?.absoluteString ?? "no address") — \(tab.title)")
            }
        }

        let (pids, incomplete) = MemoryMonitor.shared.identifiedProcesses()
        lines.append("\n== Processes\(incomplete ? " (some could not be identified)" : "")")
        for pid in pids.sorted() {
            let footprint = MemoryMonitor.footprint(of: pid).map { "\($0.bytes / 1_048_576) MB" } ?? "gone"
            lines.append("\(pid) \(Self.processName(pid)) \(footprint)")
        }
        return lines.joined(separator: "\n")
    }

    /// What the page believes about the screen it is on, for telling a page
    /// that is drawing itself at the wrong scale from one that only looks so.
    private static func pageMetrics(_ view: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            var done = false
            view.evaluateJavaScript("JSON.stringify({devicePixelRatio: window.devicePixelRatio, innerWidth: innerWidth, innerHeight: innerHeight, zoom: getComputedStyle(document.documentElement).zoom, visibility: document.visibilityState})") { value, error in
                guard !done else { return }
                done = true
                continuation.resume(returning: value as? String ?? "could not ask: \(error?.localizedDescription ?? "?")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !done else { return }
                done = true
                continuation.resume(returning: "no answer in 3s")
            }
        }
    }

    // MARK: - Pictures

    private static func snapshot(_ view: WKWebView) async -> Data? {
        await withCheckedContinuation { continuation in
            var done = false
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            view.takeSnapshot(with: configuration) { image, _ in
                guard !done else { return }
                done = true
                continuation.resume(returning: image.flatMap(Self.png))
            }
            // WebKit answers a page that cannot paint late or never.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard !done else { return }
                done = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// The window's own drawing: sidebar, bars and frame. Web content is
    /// composited by another process and comes out blank here, which is what
    /// the page snapshots are for.
    private static func chrome(of window: NSWindow) -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - The system log

    /// Only what Drift's own processes wrote: the app and the WebKit helpers
    /// it is using right now, found by process number so nothing from another
    /// WebKit app is swept up.
    private static func systemLog() async -> String {
        let (pids, _) = MemoryMonitor.shared.identifiedProcesses()
        let predicate = pids.sorted().map { "processIdentifier == \($0)" }.joined(separator: " OR ")
        do {
            let output = try await run("/usr/bin/log", ["show", "--last", logWindow, "--style", "compact", "--predicate", predicate], timeout: 90)
            return output.isEmpty ? "(nothing in the last \(logWindow))" : output
        } catch {
            return "could not read the system log: \(error.localizedDescription)"
        }
    }

    // MARK: - Odds and ends

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { return continuation.resume(throwing: error) }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Read before waiting, or a chatty tool fills the pipe and stalls.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                let text = String(decoding: data.prefix(4_000_000), as: UTF8.self)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: text + "\n(stopped after \(Int(timeout))s)")
                } else {
                    continuation.resume(returning: text)
                }
            }
        }
    }

    private static func write(_ text: String, to folder: URL, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func destination(_ stamp: String) -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent("Drift-debug-\(stamp).zip")
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    static func slug(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        let lowered = text.lowercased().map { allowed.contains($0) ? $0 : "-" }
        return String(String(lowered).prefix(40))
    }

    private static func runningFor() -> String {
        guard let started = MemoryMonitor.footprint(of: getpid())?.started else { return "?" }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let elapsed = Double(mach_absolute_time() - started) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return elapsed < 120 ? "\(Int(elapsed))s" : "\(Int(elapsed / 60)) min"
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(cString: buffer)
    }
}
