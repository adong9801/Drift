import AppKit
import WebKit

/// One installed extension, as remembered between launches.
struct InstalledExtension: Codable, Identifiable, Equatable {
    /// Its folder under Extensions/, and the identity WebKit files its storage
    /// under. Stable for the life of the install, so settings and logins stick.
    let id: String
    var enabled: Bool
    /// Where it came from, so it can be fetched again to update.
    var source: String?
    /// Whether it has been given its installed event; see `Extensions.prime`.
    /// Optional so that records saved before this existed still load, as unprimed.
    var primed: Bool?
    /// Hosts it may run on, when it asked for every site and that is more than
    /// it needs. Nil means wherever it asked. See `Extensions.setSites`.
    var sites: [String]?
    /// Whether it may see and run in private windows. Off unless switched on:
    /// an extension is someone else's code with storage of its own, and what
    /// it noted down about a private tab would outlive the session.
    var allowedInPrivate: Bool?
    /// Whether its button is pinned to the toolbar. Unpinned, it is reached
    /// from the extensions menu. One installed now starts unpinned, as in
    /// Chrome, so the toolbar holds only what was chosen for it; nil, as for
    /// every record saved before pinning could be chosen, means pinned, so
    /// a toolbar already set up stays as it was.
    var pinned: Bool?
    var isPinned: Bool { pinned != false }

    /// "canvas.school.edu, *.instructure.com" as match patterns, dropping
    /// anything that is not one.
    var sitePatterns: [WKWebExtension.MatchPattern] {
        (sites ?? []).compactMap { InstalledExtension.pattern(for: $0) }
    }

    static func pattern(for host: String) -> WKWebExtension.MatchPattern? {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return try? WKWebExtension.MatchPattern(string: trimmed) }
        return try? WKWebExtension.MatchPattern(string: "*://\(trimmed)/*")
    }
}

/// What happened to each extension as it loaded, kept in a small file beside
/// the rest of Drift's data. Extensions fail without a sound, and "it didn't
/// work" is not something that can be debugged; this is what gets read instead.
enum ExtensionLog {
    private static let file = Storage.directory.appendingPathComponent("extensions.log")

    static func note(_ text: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon))
        let line = "\(stamp) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            // Start again rather than grow for ever.
            if (try? handle.seekToEnd()) ?? 0 > 200_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

/// Runs web extensions: the standard WebExtensions format that Chrome, Firefox
/// and Safari extensions are written in, through WebKit's own engine. That
/// makes coverage the same as Safari's. Most of an extension's APIs work; ones
/// only Chrome has do not, and an extension that cannot live without them will
/// load and then sit there.
///
/// WebKit does the running. What it needs from the browser is what this file
/// supplies: where the files are, what the tabs and the window look like, a
/// button to hang the popup off, and someone to ask about permissions.
@MainActor
final class Extensions: NSObject, ObservableObject {

    static let shared = Extensions()

    let controller: WKWebExtensionController
    let window = ExtensionWindow(store: .shared)
    /// The private window, for as long as one is open.
    private(set) var privateWindow: ExtensionWindow?

    /// Whether any extension has been let into private windows, which is
    /// when private tabs are attached to the controller at all.
    var anyAllowedInPrivate: Bool { installed.contains { $0.enabled && $0.allowedInPrivate == true } }

    func privateWindowOpened(_ store: BrowserStore) {
        let fresh = ExtensionWindow(store: store)
        privateWindow = fresh
        controller.didOpenWindow(fresh)
    }

    func privateWindowClosed() {
        guard let gone = privateWindow else { return }
        privateWindow = nil
        controller.didCloseWindow(gone)
    }

    /// Lets an extension into private windows, or out of them. WebKit does
    /// the hiding: an extension without access is not told of private tabs
    /// and does not run in them.
    func setAllowedInPrivate(_ record: InstalledExtension, _ allowed: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        installed[index].allowedInPrivate = allowed
        save()
        contexts[record.id]?.hasAccessToPrivateData = allowed
        ExtensionLog.note("\(name(of: record)) \(allowed ? "allowed in" : "kept out of") private windows")
    }

    @Published private(set) var installed: [InstalledExtension]
    /// The ones currently loaded, by id.
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when an extension changes its button, so the toolbar redraws.
    @Published private(set) var revision = 0
    /// Every installed extension is loaded and knows about the window and its
    /// tabs. No page is shown before this, because a page that loads first
    /// races the extensions: its content scripts arrive late or not at all, and
    /// their first message to a background page that does not yet know the tab
    /// fails with "Tab not found". BetterCampus read that as having no
    /// settings and crashed on every launch that restored a Canvas tab.
    @Published private(set) var isReady = false
    @Published var busy = false
    @Published var lastError: String?

    /// The popup on screen, if any, and the action it belongs to: closing goes
    /// through the action so the extension hears about it.
    private weak var openPopover: NSPopover?
    private weak var openAction: WKWebExtension.Action?

    /// Reading an action's popup accessor can create its web view. Resource
    /// accounting must only inspect a popup that the user actually opened.
    var visiblePopupWebView: WKWebView? {
        guard openPopover?.isShown == true else { return nil }
        return openAction?.popupWebView
    }

    /// The toolbar button each popup hangs off, by extension id.
    private var anchors: [String: WeakView] = [:]
    private struct WeakView { weak var view: NSView? }

    /// The scheme extensions' own pages are served under. WebKit's default for
    /// browsers other than Safari is `webkit-extension`, which no extension has
    /// heard of: they check their own addresses against a list of
    /// `chrome-extension`, `moz-extension` and `safari-web-extension`, and treat
    /// anything else as an impostor. Bitwarden does exactly that before building
    /// its in-field menu, which left the menu an empty sliver two pixels tall.
    /// This is the one of the three that is true of the engine.
    static let scheme = "safari-web-extension"

    private static let file = "extensions.json"
    private static let folder: URL = {
        let folder = Storage.directory.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private override init() {
        // A fixed identifier keeps extension storage in one place across
        // launches. Tests get an identifier of their own, wiped at the start of
        // each run, but still a persistent one: a non-persistent controller
        // keeps no record of versions, so the installed event behaves
        // differently there and a test on it proves nothing about the app.
        let scratch = ProcessInfo.processInfo.environment["DRIFT_DATA_DIR"] != nil
        let identifier = UUID(uuidString: scratch ? "7E570000-5E2B-4C19-9A77-D21F70000002" : "6D1F7A00-5E2B-4C19-9A77-D21F70000001")!
        if scratch { Self.wipeWebKitState(for: identifier) }
        let configuration = WKWebExtensionController.Configuration(identifier: identifier)

        // What an extension's own pages (background, popup, options) say they
        // are. Extensions sniff this to pick a code path, and both obvious
        // answers are wrong: WebKit's bare user agent names no browser at all,
        // which Bitwarden takes as "unknown" and crashes on; and "Safari" sends
        // it down a path that waits for Safari's native app bridge, for ever.
        // Firefox is the honest answer, since Firefox builds are what load best
        // here: same `browser.*` promise API, background pages rather than
        // Chrome's service workers. Web pages in tabs are unaffected and still
        // see Safari.
        let pages = WKWebViewConfiguration()
        pages.applicationNameForUserAgent = "Firefox/130.0"
        // Inspect Element in an extension's popup and options pages.
        if pages.preferences.responds(to: Selector(("_setDeveloperExtrasEnabled:"))) {
            pages.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        // A popup is a new page each time it opens; see `Tab.turnOffWebGPU`.
        Tab.turnOffWebGPU(pages.preferences)
        // Keeps the last errors an extension's own pages threw, for
        // `diagnostics()`. Extensions fail silently as a rule, and this is the
        // only record there is. Nothing leaves the machine unless the user
        // copies it out.
        pages.userContentController.addUserScript(
            WKUserScript(source: Self.errorRecorder, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.webViewConfiguration = pages

        // Must happen before any extension loads under it; see `load`.
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.scheme)

        controller = WKWebExtensionController(configuration: configuration)
        installed = Storage.load([InstalledExtension].self, from: Self.file) ?? []
        super.init()
        controller.delegate = self
        // A broken extension must not be able to hold the browser shut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.isReady == false { self?.isReady = true }
        }
    }

    /// Removes what WebKit has kept for a controller, under this process's own
    /// folder. Only ever called for the test identifier.
    private static func wipeWebKitState(for identifier: UUID) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let folder = library.appendingPathComponent("WebKit/\(owner)/WebExtensions/\(identifier.uuidString)")
        try? FileManager.default.removeItem(at: folder)
    }

    /// Loads what is installed and tells WebKit the window exists. Once, at launch.
    func start() async {
        // All at once: each is mostly waiting on its own files.
        await withTaskGroup(of: Void.self) { group in
            for record in installed where record.enabled {
                group.addTask { await self.load(record) }
            }
        }
        // Told about the window and its tabs only now, with the extensions there
        // to hear it. Tabs restored from the last session were never announced
        // one by one, so this is where they become known.
        controller.didOpenWindow(window)
        for tab in BrowserStore.shared.tabs { controller.didOpenTab(tab) }
        controller.didFocusWindow(window)
        if let focused = BrowserStore.shared.focused {
            controller.didActivateTab(focused, previousActiveTab: nil)
        }
        isReady = true

        // `-installExtensions /a:/b` on the command line installs without
        // asking. For setting the app up from a script.
        if let paths = UserDefaults.standard.string(forKey: "installExtensions") {
            for path in paths.split(separator: ":") {
                try? await install(from: URL(fileURLWithPath: String(path)), source: nil, confirm: false)
            }
        }
    }

    // MARK: - What is installed

    func context(_ id: String) -> WKWebExtensionContext? { contexts[id] }

    /// Whether it wants to read every site, which is when confining it is worth offering.
    func asksForEverySite(_ record: InstalledExtension) -> Bool {
        contexts[record.id]?.webExtension.allRequestedMatchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs } ?? false
    }

    func name(of record: InstalledExtension) -> String {
        contexts[record.id]?.webExtension.displayName ?? manifestName(record) ?? "Extension"
    }

    func version(of record: InstalledExtension) -> String {
        contexts[record.id]?.webExtension.displayVersion ?? ""
    }

    func icon(of record: InstalledExtension, size: CGFloat) -> NSImage? {
        guard let context = contexts[record.id] else { return nil }
        let box = CGSize(width: size, height: size)
        return context.action(for: BrowserStore.shared.focused)?.icon(for: box) ?? context.webExtension.icon(for: box)
    }

    /// Enabled extensions that want a toolbar button.
    var actionable: [InstalledExtension] {
        installed.filter { contexts[$0.id]?.action(for: nil) != nil }
    }

    /// The installed extension that is this Chrome Web Store item: by the
    /// store link it was installed from, or, for one installed from a file,
    /// by name.
    func installed(storeID id: String, name: String?) -> InstalledExtension? {
        installed.first { $0.source.flatMap(ExtensionSource.storeID(in:)) == id }
            ?? name.flatMap { name in installed.first { self.name(of: $0) == name } }
    }

    /// The ones pinned to the toolbar.
    var toolbar: [InstalledExtension] {
        actionable.filter(\.isPinned)
    }

    func setPinned(_ record: InstalledExtension, _ pinned: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        installed[index].pinned = pinned
        save()
    }

    /// The name straight from the manifest, for an extension that is switched
    /// off and so has no context to ask.
    private func manifestName(_ record: InstalledExtension) -> String? {
        let manifest = Self.folder.appendingPathComponent(record.id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (json["short_name"] as? String) ?? (json["name"] as? String),
              !name.hasPrefix("__MSG_")
        else { return nil }
        return name
    }

    // MARK: - Installing

    enum InstallError: LocalizedError {
        case notAnExtension
        case unreadable(String)
        case download(String)
        case declined

        var errorDescription: String? {
            switch self {
            case .notAnExtension: return "There is no manifest.json in that, so it is not a web extension."
            case .unreadable(let why): return "WebKit could not read the extension: \(why)"
            case .download(let why): return "The download failed: \(why)"
            case .declined: return "Not installed."
            }
        }
    }

    /// A Chrome Web Store page, or a direct link to a .zip, .crx or .xpi.
    func install(fromWeb text: String) async {
        await run {
            guard let link = ExtensionSource.downloadURL(for: text) else {
                throw InstallError.download("That is not a Chrome Web Store link or a link to a .zip, .crx or .xpi.")
            }
            let (file, response) = try await URLSession.shared.download(from: link)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                throw InstallError.download("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            try await self.install(from: file, source: text, confirm: true)
        }
    }

    func install(fromFile url: URL) async {
        await run { try await self.install(from: url, source: nil, confirm: true) }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            try await work()
        } catch InstallError.declined {
            // Saying no is not an error.
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// `url` is an unpacked folder or an archive. It is copied in, so the
    /// original can be thrown away afterwards.
    func install(from url: URL, source: String?, confirm: Bool) async throws {
        let id = UUID().uuidString
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("drift-ext-\(id)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if isFolder.boolValue {
            try FileManager.default.copyItem(at: url, to: staging)
        } else {
            try Self.unpack(url, into: staging)
        }
        guard let root = ExtensionSource.manifestRoot(in: staging) else { throw InstallError.notAnExtension }

        let parsed: WKWebExtension
        do { parsed = try await WKWebExtension(resourceBaseURL: root) } catch {
            throw InstallError.unreadable(error.localizedDescription)
        }
        if confirm, !Self.confirmInstall(of: parsed) { throw InstallError.declined }

        // The same extension again is an update: keep its id, and with it its
        // storage, and swap the files underneath.
        let name = parsed.displayName
        let existing = installed.first { contexts[$0.id]?.webExtension.displayName == name && name != nil }
        let record = existing ?? InstalledExtension(id: id, enabled: true, source: source, pinned: false)
        if let existing { unload(existing.id) }

        let home = Self.folder.appendingPathComponent(record.id, isDirectory: true)
        try? FileManager.default.removeItem(at: home)
        try FileManager.default.moveItem(at: root, to: home)

        if existing == nil { installed.append(record) }
        if let index = installed.firstIndex(where: { $0.id == record.id }) {
            installed[index].enabled = true
            if let source { installed[index].source = source }
            // Installed over itself at the same version, WebKit would see no
            // change and send nothing. Priming again makes sure it does.
            installed[index].primed = false
        }
        save()
        await load(installed.first { $0.id == record.id } ?? record)
    }

    /// Archives are zips, a .crx being one with a signed header stuck on the
    /// front. `unzip` skips that header, mutters, and exits 1, which is fine.
    private static func unpack(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", archive.path, "-d", folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus <= 1 else { throw InstallError.notAnExtension }
    }

    private static func confirmInstall(of parsed: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install \u{201C}\(parsed.displayName ?? "this extension")\u{201D}?"
        let everywhere = parsed.allRequestedMatchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let permissions = parsed.requestedPermissions.map(\.rawValue).sorted().joined(separator: ", ")
        alert.informativeText = (everywhere
            ? "It can read and change every page you visit, passwords and all. "
            : "It can read and change pages on the sites it names. ")
            + "Only install extensions you trust."
            + (permissions.isEmpty ? "" : "\n\nIt asks for: \(permissions).")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Loading

    /// Makes sure the extension gets a `runtime.onInstalled` event.
    ///
    /// Outside Safari, WebKit never sends one for a first install: a brand-new
    /// extension gets `onStartup` and nothing else, and only a change of version
    /// produces `onInstalled`, as an update. Plenty of extensions do their
    /// setting-up in that event. BetterCampus writes all its default settings
    /// there, and without them its page component crashed on the first one it
    /// read, on every Canvas page.
    ///
    /// So before the first real load, an empty stand-in is loaded and unloaded
    /// under the same identity at version 0. It has no code to run. WebKit
    /// records the version, and the real load that follows is a version change.
    /// The event arrives with reason "update" rather than "install", which
    /// costs a welcome page and nothing else. The extension's stored data is
    /// untouched; that was checked, since a password manager's login lives there.
    private func prime(_ record: InstalledExtension, manifestVersion: Double) async -> Bool {
        let stand = FileManager.default.temporaryDirectory.appendingPathComponent("drift-prime-\(record.id)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stand) }
        do {
            try? FileManager.default.removeItem(at: stand)
            try FileManager.default.createDirectory(at: stand, withIntermediateDirectories: true)
            let manifest = #"{"manifest_version":\#(Int(manifestVersion)),"name":"Drift stand-in","version":"0"}"#
            try Data(manifest.utf8).write(to: stand.appendingPathComponent("manifest.json"))
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: stand))
            context.uniqueIdentifier = record.id
            if let base = URL(string: "\(Self.scheme)://\(record.id.lowercased())/") { context.baseURL = base }
            try controller.load(context)
            try controller.unload(context)
            ExtensionLog.note("primed \(manifestName(record) ?? record.id)")
            return true
        } catch {
            // Without it the extension still loads; it just may not set itself up.
            lastError = "\(manifestName(record) ?? "An extension") could not be prepared: \(error.localizedDescription)"
            ExtensionLog.note("priming FAILED for \(manifestName(record) ?? record.id): \(error)")
            return false
        }
    }

    private func load(_ record: InstalledExtension) async {
        guard contexts[record.id] == nil else { return }
        let home = Self.folder.appendingPathComponent(record.id, isDirectory: true)
        do {
            let parsed = try await WKWebExtension(resourceBaseURL: home)
            if record.primed != true {
                // Only marked done if it was, so a failure is tried again next launch.
                let done = await prime(record, manifestVersion: parsed.manifestVersion)
                if done, let index = installed.firstIndex(where: { $0.id == record.id }) {
                    installed[index].primed = true
                    save()
                }
            }
            let context = WKWebExtensionContext(for: parsed)
            context.uniqueIdentifier = record.id
            context.isInspectable = true
            context.hasAccessToPrivateData = record.allowedInPrivate ?? false
            // Its own id as the host, so the address, and the storage keyed to
            // it, stay the same from one launch to the next.
            if let base = URL(string: "\(Self.scheme)://\(record.id.lowercased())/") {
                context.baseURL = base
            }
            // Installing was the consent. Asking again per permission on every
            // page would only teach the user to click through.
            for permission in parsed.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            Self.grantSites(of: record, to: context)
            try controller.load(context)
            contexts[record.id] = context
            ExtensionLog.note("loaded \(parsed.displayName ?? record.id) \(parsed.displayVersion ?? "") at \(context.baseURL.absoluteString)\(context.errors.isEmpty ? "" : " with errors: \(context.errors.map(\.localizedDescription))")")
            // Not awaited: an extension leaning on something WebKit lacks can
            // leave this hanging for good, and the rest of the browser should
            // not wait with it. One with nothing to run in the background, only
            // scripts for pages (Modern for Wikipedia), is not asked: WebKit
            // answers that with an error, which read as "did not start".
            if parsed.hasBackgroundContent { context.loadBackgroundContent { [weak self] error in
                ExtensionLog.note("background of \(parsed.displayName ?? record.id): \(error.map { "FAILED \($0.localizedDescription)" } ?? "running")")
                guard let error else { return }
                Task { @MainActor in
                    self?.lastError = "\(parsed.displayName ?? "An extension") did not start: \(error.localizedDescription)"
                }
            } }
            revision += 1
        } catch {
            lastError = "\(manifestName(record) ?? "An extension") could not be loaded: \(error.localizedDescription)"
            ExtensionLog.note("load FAILED for \(manifestName(record) ?? record.id): \(error)")
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        revision += 1
    }

    func setEnabled(_ record: InstalledExtension, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        installed[index].enabled = enabled
        save()
        if enabled {
            Task { await load(installed[index]) }
        } else {
            unload(record.id)
        }
    }

    /// Confines an extension that asked for every site to the hosts given,
    /// such as a Canvas helper that need not read Reddit. Nil lifts the limit.
    func setSites(_ record: InstalledExtension, _ hosts: [String]?) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        let cleaned = hosts?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        installed[index].sites = (cleaned?.isEmpty ?? true) ? nil : cleaned
        save()
        if let context = contexts[record.id] { Self.grantSites(of: installed[index], to: context) }
    }

    /// Every site it asked for, unless it has been confined: then the patterns
    /// that cover every host are refused outright, so WebKit never asks, and
    /// its named hosts plus the user's list are allowed instead.
    static func grantSites(of record: InstalledExtension, to context: WKWebExtensionContext) {
        let requested = context.webExtension.allRequestedMatchPatterns
        let confined = record.sites != nil
        for pattern in requested {
            let broad = pattern.matchesAllHosts || pattern.matchesAllURLs
            context.setPermissionStatus(confined && broad ? .deniedExplicitly : .grantedExplicitly, for: pattern)
        }
        // Lifted, or edited: whatever was allowed before and is not now, goes.
        for pattern in context.grantedPermissionMatchPatterns.keys where !requested.contains(pattern) {
            context.setPermissionStatus(.unknown, for: pattern)
        }
        for pattern in record.sitePatterns where !requested.contains(pattern) {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    func remove(_ record: InstalledExtension) {
        unload(record.id)
        installed.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(record.id))
        save()
    }

    private func save() { Storage.save(installed, to: Self.file) }

    // MARK: - Toolbar

    func registerAnchor(_ view: NSView, for id: String) {
        anchors[id] = WeakView(view: view)
    }

    /// The extensions button, which a popup hangs from when its own button
    /// is not in the toolbar.
    static let menuAnchor = "drift.extensions-button"

    /// Where an extension's popup hangs from: its own button if pinned and
    /// on screen, else the extensions button. Nil with neither showing.
    func popupAnchor(for id: String) -> NSView? {
        [id, Self.menuAnchor].lazy.compactMap { self.anchors[$0]?.view }.first { $0.window != nil }
    }

    /// Closes the extension popup that is showing. False if none was, so the
    /// caller can go on to whatever Cmd-W would otherwise mean.
    @discardableResult
    func closeOpenPopup() -> Bool {
        guard let popover = openPopover, popover.isShown else { return false }
        if let action = openAction { action.closePopup() } else { popover.close() }
        openPopover = nil
        openAction = nil
        BrowserStore.shared.focused?.focus()
        return true
    }

    /// A click on the extension's button. WebKit decides what that means: a
    /// popup, which comes back through the delegate, or a click event.
    func perform(_ record: InstalledExtension) {
        guard let context = contexts[record.id] else { return }
        let focused = WindowRouter.shared.active.focused
        context.performAction(for: focused?.isPrivate == true && !context.hasAccessToPrivateData ? nil : focused)
    }

    func openOptions(_ record: InstalledExtension) {
        guard let url = contexts[record.id]?.optionsPageURL else { return }
        BrowserStore.shared.newTab(url)
    }

    /// The items extensions want in a page's right-click menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        contexts.values.flatMap { $0.menuItems(for: tab) }
    }

    /// A key press an extension has claimed as a shortcut.
    func performCommand(for event: NSEvent) -> Bool {
        contexts.values.contains { $0.performCommand(for: event) }
    }

    // MARK: - Diagnostics

    private static let errorRecorder = """
    (function () {
      if (globalThis.__driftLog) return;
      var log = globalThis.__driftLog = [];
      function keep(kind, text) {
        log.push(new Date().toISOString().slice(11, 19) + ' ' + kind + ': ' + String(text).slice(0, 400));
        if (log.length > 200) log.shift();
      }
      function say(value) { return (value && (value.stack || value.message)) || String(value); }
      globalThis.addEventListener('error', function (e) { keep('error', e.message + ' @ ' + String(e.filename || '').split('/').pop() + ':' + e.lineno); });
      globalThis.addEventListener('unhandledrejection', function (e) { keep('rejection', say(e.reason)); });
      ['error', 'warn'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try { keep(level, Array.prototype.map.call(arguments, say).join(' ')); } catch (_) {}
          return original.apply(console, arguments);
        };
      });
    })();
    """

    /// What each extension can see of the page in front, and what has gone
    /// wrong in its background page. Field names and types, never what is
    /// typed in them.
    private static let probe = """
    var out = { log: (globalThis.__driftLog || []).slice(-60) };
    function within(ms, promise) {
      return Promise.race([promise, new Promise(function (done) { setTimeout(function () { done('no answer in ' + ms + 'ms'); }, ms); })]);
    }
    try {
      var tab = (await browser.tabs.query({ active: true, currentWindow: true }))[0];
      out.tab = tab ? { id: tab.id, url: tab.url, status: tab.status } : 'no active tab';
      if (tab) {
        // Only extensions that asked for webNavigation have it.
        if (browser.webNavigation) {
          var frames = await within(3000, browser.webNavigation.getAllFrames({ tabId: tab.id }));
          out.frames = Array.isArray(frames) ? frames.map(function (f) { return { id: f.frameId, url: String(f.url).slice(0, 90) }; }) : frames;
        }
        // Names only: what an extension stores can be private.
        if (browser.storage && browser.storage.local) {
          out.storedKeys = Object.keys(await within(3000, browser.storage.local.get(null)) || {}).slice(0, 40);
        }
        var details = await within(4000, browser.tabs.sendMessage(tab.id, { command: 'collectPageDetailsImmediately' }, { frameId: 0 }));
        if (details && details.fields) {
          out.detailsUrl = details.url;
          out.fields = details.fields.map(function (f) {
            return { type: f.type, name: f.htmlName || f.htmlID, viewable: f.viewable, readonly: f.readonly, disabled: f.disabled };
          });
        } else {
          out.fields = String(details);
        }
      }
    } catch (e) { out.problem = e.message; }
    return JSON.stringify(out, null, 1);
    """

    /// What the page in front says about its sound, beside what WebKit says is
    /// actually coming out. "Playing but silent" has several causes that look
    /// the same from a chair, and these two tell them apart.
    private func mediaReport() async -> String {
        guard let tab = WindowRouter.shared.active.focused, let view = tab.webView else { return "\n== Media\nno page in front" }
        var lines = ["\n== Media on \(tab.url?.host ?? "this page")"]
        if view.responds(to: Selector(("_isPlayingAudio"))) {
            lines.append("WebKit says sound is coming out of this tab: \((view.value(forKey: "_isPlayingAudio") as? Bool) ?? false)")
        }
        if view.responds(to: Selector(("_mediaMutedState"))) {
            lines.append("WebKit's mute state for this tab (0 is not muted): \(view.value(forKey: "_mediaMutedState") ?? "?")")
        }
        let script = """
        (function () {
          var found = Array.prototype.map.call(document.querySelectorAll('video, audio'), function (m) {
            return { tag: m.tagName.toLowerCase(), paused: m.paused, time: Math.round(m.currentTime), muted: m.muted, volume: m.volume,
                     audioTracks: m.audioTracks ? m.audioTracks.length : -1, ready: m.readyState, mode: m.webkitPresentationMode || null };
          });
          var contexts = (typeof AudioContext !== 'undefined') ? 'available' : 'missing';
          return JSON.stringify({ media: found, audioContext: contexts, visibility: document.visibilityState }, null, 1);
        })()
        """
        let page: String = await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: value as? String ?? "could not ask the page: \(error?.localizedDescription ?? "?")")
            }
        }
        lines.append(page)
        lines.append(SoundOutput.summary())
        return lines.joined(separator: "\n")
    }

    /// A report to paste into a bug hunt. Reaches the background page through a
    /// property WebKit does not publish, so it checks first and says so if it
    /// has gone.
    func diagnostics() async -> String {
        var report = ["Drift diagnostics, \(Date().formatted(date: .abbreviated, time: .standard))"]
        report.append(await mediaReport())
        for record in installed {
            report.append("\n== \(name(of: record)) \(version(of: record)) [\(record.enabled ? "on" : "off")]")
            guard let context = contexts[record.id] else { continue }
            report.append("address: \(context.baseURL.absoluteString)")
            if !context.errors.isEmpty {
                report.append("webkit errors: " + context.errors.map(\.localizedDescription).joined(separator: " | "))
            }
            guard context.responds(to: Selector(("_backgroundWebView"))),
                  let background = context.value(forKey: "_backgroundWebView") as? WKWebView
            else {
                report.append("background page: not reachable")
                continue
            }
            let answer: String = await withCheckedContinuation { continuation in
                background.callAsyncJavaScript(Self.probe, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "no report")
                    case .failure(let error): continuation.resume(returning: "probe failed: \(error.localizedDescription)")
                    }
                }
            }
            report.append(answer)
        }
        return report.joined(separator: "\n")
    }

    /// The configuration an extension's own pages must be shown with.
    func configuration(forPageAt url: URL) -> WKWebViewConfiguration? {
        controller.extensionContext(for: url)?.webViewConfiguration
    }
}

// MARK: - What WebKit asks the browser

extension Extensions: WKWebExtensionControllerDelegate {

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        // The private window only for extensions let into it: WebKit is
        // meant to keep it from the rest, and this makes sure.
        [window] + (extensionContext.hasAccessToPrivateData ? (privateWindow.map { [$0] } ?? []) : [])
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        WindowRouter.shared.active.isPrivateWindow && extensionContext.hasAccessToPrivateData ? (privateWindow ?? window) : window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let url = configuration.url else { return completionHandler(nil, nil) }
        let tab = BrowserStore.shared.newTab(url, inBackground: !configuration.shouldBeActive, pinned: configuration.shouldBePinned)
        completionHandler(tab, nil)
    }

    /// There is one window, so a request for another becomes tabs in this one.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        for url in configuration.tabURLs { BrowserStore.shared.newTab(url) }
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL { BrowserStore.shared.newTab(url) }
        completionHandler(nil)
    }

    /// Permissions the extension did not declare up front and is asking for now.
    // Installing an extension was the consent to what it asked for, and
    // asking again each time it wants a site would only teach the user to
    // click through. So there are no prompts: an extension gets what it asks
    // for, unless it has been confined to certain sites, in which case only
    // those, quietly. Anything refused is noted in the extension log.

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        ExtensionLog.note("\(extensionContext.webExtension.displayName ?? "an extension") asked for \(permissions.map(\.rawValue).sorted().joined(separator: ", ")): granted")
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let allowed = urls.filter { url in allowedSites(of: extensionContext)?.contains { $0.matches(url) } ?? true }
        ExtensionLog.note("\(extensionContext.webExtension.displayName ?? "an extension") asked to read \(urls.compactMap(\.host).sorted().joined(separator: ", ")): \(allowed.count == urls.count ? "granted" : "\(allowed.count) of \(urls.count) granted, the rest outside its sites")")
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let allowed: Set<WKWebExtension.MatchPattern>
        if let sites = allowedSites(of: extensionContext) {
            // A pattern is let through if some allowed site covers it, which a
            // host-wide pattern of the extension's own never is.
            allowed = matchPatterns.filter { pattern in sites.contains { $0.matches(pattern) } }
        } else {
            allowed = matchPatterns
        }
        ExtensionLog.note("\(extensionContext.webExtension.displayName ?? "an extension") asked for \(matchPatterns.map(\.string).sorted().joined(separator: ", ")): \(allowed.count == matchPatterns.count ? "granted" : "\(allowed.count) of \(matchPatterns.count) granted, the rest outside its sites")")
        completionHandler(allowed, nil)
    }

    /// The sites an extension has been confined to, or nil for no limit.
    private func allowedSites(of context: WKWebExtensionContext) -> [WKWebExtension.MatchPattern]? {
        guard let record = installed.first(where: { $0.id == context.uniqueIdentifier }), record.sites != nil else { return nil }
        return record.sitePatterns + context.webExtension.allRequestedMatchPatterns.filter { !$0.matchesAllHosts && !$0.matchesAllURLs }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        revision += 1
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        closeOpenPopup()
        // Goes away on a click elsewhere, like any other menu.
        popover.behavior = .transient
        openPopover = popover
        openAction = action
        // The sidebar it hangs off may be only peeking out; hold it there.
        BrowserStore.shared.peekHeld = true
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated {
                BrowserStore.shared.peekHeld = false
                guard let self, self.openPopover === popover else { return }
                self.openPopover = nil
                self.openAction = nil
            }
        }
        // Off its own button if that is on screen, else the extensions button
        // it was opened from, else the window's corner. A button unpinned
        // leaves its entry behind, gone or out of the window, so each is
        // tried in turn rather than the first one found.
        if let anchor = popupAnchor(for: context.uniqueIdentifier) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView {
            let corner = NSRect(x: 40, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
        completionHandler(nil)
    }
}

// MARK: - The window, as extensions see it

/// A browser window in the shape WebKit wants: the main one, or the private
/// one while it is open. Private tabs are reported like any other; WebKit
/// shows them only to extensions given `hasAccessToPrivateData`.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {

    let store: BrowserStore

    init(store: BrowserStore) {
        self.store = store
    }

    private var real: NSWindow? { store.window ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible } }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        store.orderedTabs.filter { !$0.isPrivate || context.hasAccessToPrivateData }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        let candidate = store.focused ?? store.selected
        guard let candidate, candidate.isPrivate, !context.hasAccessToPrivateData else { return candidate }
        return nil
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let real else { return .normal }
        if real.styleMask.contains(.fullScreen) { return .fullscreen }
        return real.isMiniaturized ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { store.isPrivateWindow }

    func frame(for context: WKWebExtensionContext) -> CGRect { real?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { real?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        real?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }
}

// MARK: - A tab, as extensions see it

extension Tab: WKWebExtensionTab {

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        store?.isPrivateWindow == true ? Extensions.shared.privateWindow : Extensions.shared.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        store?.orderedTabs.firstIndex { $0.id == id } ?? NSNotFound
    }

    /// Nil for a tab that has not been opened since launch. Extensions see its
    /// address and title all the same, and simply cannot script it yet.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? { displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.isVisible(self) ?? false }
    func size(for context: WKWebExtensionContext) -> CGSize { webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.map { Double($0.pageZoom) } ?? 1 }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if pinned != isPinned { store?.togglePin(self) }
        completionHandler(nil)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store?.select(self)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store?.close(self)
        completionHandler(nil)
    }
}
