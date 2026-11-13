import Foundation
import WebKit

/// Compiles the block list once and hands it to every tab.
///
/// The compiled list is cached by WebKit under an identifier, so a normal
/// launch is a lookup, not a compile. The host list itself is refreshed from
/// the network weekly; until the first fetch lands, the built-in hosts stand in.
@MainActor
final class AdBlock: ObservableObject {

    static let shared = AdBlock()

    private static let enabledKey = "drift.adblock.enabled.v1"
    private static let fetchedKey = "drift.adblock.fetchedAt.v1"
    private static let identifier = "drift.blocklist.v1"
    /// Peter Lowe's list: small, conservative, maintained for twenty years.
    private static let source = URL(
        string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext"
    )!

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    @Published private(set) var ruleList: WKContentRuleList?
    @Published private(set) var hostCount = 0

    /// Called when the list or the switch changes, so open tabs can catch up.
    var onChange: (() -> Void)?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The list to install in a new tab, if blocking is on and one is ready.
    var active: WKContentRuleList? { enabled ? ruleList : nil }

    func prepare() async {
        if let cached = await lookUp() {
            ruleList = cached
            hostCount = UserDefaults.standard.integer(forKey: "drift.adblock.hostCount.v1")
            onChange?()
        } else {
            await compile(hosts: storedHosts() ?? BlockRules.builtIn)
        }
        await refreshIfStale()
    }

    private func refreshIfStale() async {
        let last = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86_400 else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: Self.source),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        let fetched = BlockRules.hosts(fromList: String(decoding: data, as: UTF8.self))
        // A list this short means the fetch returned an error page, not hosts.
        guard fetched.count > 500 else { return }
        let hosts = Array(Set(fetched + BlockRules.builtIn)).sorted()
        try? hosts.joined(separator: "\n").write(to: Self.hostsFile, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(Date(), forKey: Self.fetchedKey)
        await compile(hosts: hosts)
    }

    private func compile(hosts: [String]) async {
        let json = BlockRules.json(hosts: hosts)
        let compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: Self.identifier,
                encodedContentRuleList: json
            ) { list, _ in continuation.resume(returning: list) }
        }
        guard let compiled else { return }
        ruleList = compiled
        hostCount = hosts.count
        UserDefaults.standard.set(hosts.count, forKey: "drift.adblock.hostCount.v1")
        onChange?()
    }

    private func lookUp() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: Self.identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func storedHosts() -> [String]? {
        guard let text = try? String(contentsOf: Self.hostsFile, encoding: .utf8) else { return nil }
        let hosts = BlockRules.hosts(fromList: text)
        return hosts.isEmpty ? nil : hosts
    }

    private static var hostsFile: URL { Storage.directory.appendingPathComponent("blocked-hosts.txt") }
}

/// Where Drift keeps its files.
enum Storage {
    private static let writer = DispatchQueue(label: "Drift.Storage", qos: .utility)
    static let directory: URL = {
        // DRIFT_DATA_DIR points the whole app at a scratch folder, which is how
        // the smoke test runs without touching the real session and history.
        let override = ProcessInfo.processInfo.environment["DRIFT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = override ?? base.appendingPathComponent("Drift", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        writer.sync { write(value, to: name) }
    }

    static func saveAsync<T: Encodable>(_ value: T, to name: String) {
        writer.async { write(value, to: name) }
    }

    static func flush() { writer.sync {} }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}


// MARK: - Rules for private tabs

/// The compiled form of `PrivateRules`, made once at launch.
@MainActor
final class PrivateRuleList {
    static let shared = PrivateRuleList()
    private(set) var list: WKContentRuleList?

    func prepare() async {
        if list != nil { return }
        list = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: PrivateRules.identifier, encodedContentRuleList: PrivateRules.json) { compiled, error in
                if let error { ExtensionLog.note("private rules did not compile: \(error.localizedDescription)") }
                continuation.resume(returning: compiled)
            }
        }
    }
}
