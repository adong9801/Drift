import AppKit
import WebKit

/// Accounts for Drift and the WebKit processes it owns, without including
/// other browsers' processes. WebKit's PID accessors are guarded SPI, just as
/// the existing audio/PiP integration is; an unavailable reading stays unknown.
@MainActor
final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    private static let key = "drift.memoryBudgetMB.v1"

    @Published var limitMB: Int {
        didSet {
            UserDefaults.standard.set(limitMB, forKey: Self.key)
            reclaiming = false
            refresh()
        }
    }
    @Published private(set) var usedBytes: UInt64?
    @Published private(set) var processCount = 0
    @Published private(set) var incomplete = false
    @Published private(set) var status = "Measuring memory…"
    @Published private(set) var sleepingCount = 0
    private var timer: Timer?
    private var reclaiming = false
    private var checking = false
    private var lastSleep = Date.distantPast
    // Keep counting WebKit's cached processes after their last tab disappears.
    // Start time prevents an unrelated process reusing a PID from being counted.
    private var known: [pid_t: UInt64] = [:]

    private init() {
        limitMB = UserDefaults.standard.object(forKey: Self.key) as? Int ?? MemoryBudget.defaultMB
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 1
        refresh()
    }

    func identifiedProcesses() -> (Set<pid_t>, Bool) {
        var pids: Set<pid_t> = [getpid()]
        var missing = false
        func add(_ object: NSObject, _ key: String) {
            guard object.responds(to: NSSelectorFromString(key)),
                  let value = object.value(forKey: key) as? NSNumber else {
                missing = true
                return
            }
            if value.int32Value > 0 { pids.insert(value.int32Value) }
        }
        var views = BrowserStore.all.flatMap(\.tabs).compactMap(\.webView)
        for context in Extensions.shared.contexts.values {
            if context.responds(to: NSSelectorFromString("_backgroundWebView")),
               let background = context.value(forKey: "_backgroundWebView") as? WKWebView {
                views.append(background)
            } else if context.webExtension.hasBackgroundContent {
                missing = true
            }
        }
        if let popup = Extensions.shared.visiblePopupWebView { views.append(popup) }
        for view in views {
            add(view, "_webProcessIdentifier")
            add(view, "_gpuProcessIdentifier")
            add(view.configuration.websiteDataStore, "_networkProcessIdentifier")
        }
        return (pids, missing)
    }

    static func footprint(of pid: pid_t) -> (bytes: UInt64, started: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_proc_start_abstime)
    }

    func refresh() {
        guard !checking else { return }
        let (current, missing) = identifiedProcesses()
        var total: UInt64 = 0
        var live: [pid_t: UInt64] = [:]
        var partial = missing
        for pid in current.union(known.keys) {
            guard let sample = Self.footprint(of: pid) else {
                if current.contains(pid) { partial = true }
                continue
            }
            guard current.contains(pid) || known[pid] == sample.started else { continue }
            total += sample.bytes
            live[pid] = sample.started
        }
        known = live
        usedBytes = live.isEmpty ? nil : total
        processCount = live.count
        incomplete = partial
        let tabs = BrowserStore.all.flatMap(\.tabs)
        sleepingCount = tabs.filter(\.isAsleep).count
        guard let usedBytes else { status = "Memory measurement unavailable"; return }
        guard MemoryBudget.needsReclaim(bytes: usedBytes, limitMB: limitMB, reclaiming: reclaiming) else {
            reclaiming = false
            status = limitMB == 0 ? "Memory budget is off" : "Within budget"
            return
        }
        reclaiming = true
        guard Date().timeIntervalSince(lastSleep) >= MemoryBudget.settlingTime else { return }
        // Oldest first, one at a time. Re-measure after WebKit has had time to
        // release the process, rather than guessing how much each tab costs.
        let candidates = tabs.filter {
            !$0.isAsleep && !$0.isLoading && $0.store?.isVisible($0) == false
                && Date().timeIntervalSince($0.lastActive) >= 30
        }.sorted { $0.lastActive < $1.lastActive }
        checking = true
        trySleeping(candidates[...])
    }

    private func trySleeping(_ candidates: ArraySlice<Tab>) {
        guard MemoryBudget.needsReclaim(bytes: usedBytes ?? 0, limitMB: limitMB, reclaiming: true) else {
            checking = false
            return
        }
        guard let tab = candidates.first else {
            checking = false
            status = usedBytes.map { $0 > (MemoryBudget.bytes(forMB: limitMB) ?? UInt64.max) } == true
                ? "Over budget · remaining tabs are active or protected"
                : "Within budget · remaining tabs are protected"
            return
        }
        tab.activity { [weak self, weak tab] activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard MemoryBudget.needsReclaim(bytes: self.usedBytes ?? 0, limitMB: self.limitMB, reclaiming: self.reclaiming) else {
                    self.checking = false
                    self.refresh()
                    return
                }
                if let tab, self.limitMB > 0, let store = tab.store,
                   store.tabs.contains(where: { $0 === tab }), !tab.isAsleep,
                   TabSleep.shouldSleep(idleFor: Date().timeIntervalSince(tab.lastActive), limit: 30,
                                        isVisible: store.isVisible(tab), isLoading: tab.isLoading, activity: activity) {
                    tab.sleep()
                    FaviconCache.shared.trim()
                    self.lastSleep = Date()
                    self.sleepingCount = BrowserStore.all.flatMap(\.tabs).filter(\.isAsleep).count
                    self.status = "Sleeping unused tabs to reach budget…"
                    self.checking = false
                } else {
                    self.trySleeping(candidates.dropFirst())
                }
            }
        }
    }
}
