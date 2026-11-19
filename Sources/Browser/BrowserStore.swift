import AppKit
import WebKit

enum Pane {
    case primary
    case secondary
}

/// What the command bar does with the answer.
enum CommandBarMode: Equatable {
    /// Cmd-T: the result opens in a new tab.
    case newTab
    /// Cmd-L: the result replaces the focused tab's page.
    case current
    /// Split view was asked for with nothing to put in it.
    case split
}

/// The Ctrl-Tab overlay: cards by recency, tab groups among them as stacks
/// or rows (see `SwitcherLayout`), and which one is lit.
struct Switcher: Equatable {
    /// Every tab, most recently used first, as it was when the overlay opened.
    var recent: [UUID]
    var sections: [SwitcherSection] = []
    var index: Int = 0
    /// Shown open whatever its setting: the group of the tab in front.
    var openGroup: UUID?

    var entries: [SwitcherEntry] { sections.flatMap(\.entries) }
    var lit: SwitcherEntry? { entries.indices.contains(index) ? entries[index] : nil }
    /// The lit card's tab, when it is a tab and not a stack.
    var litTab: UUID? {
        if case .tab(let id) = lit { return id }
        return nil
    }
}

/// The window's state: which tabs exist, which are on screen, and the overlays
/// above them. One store per window: the main one, and a private one that
/// exists only while the private window is open.
@MainActor
final class BrowserStore: ObservableObject {

    /// The main window.
    static let shared = BrowserStore(isPrivateWindow: false)

    /// A private window's store: every tab in it is private, nothing in it is
    /// written down, and its cookies live and die with it.
    let isPrivateWindow: Bool
    /// Set by the window once it exists, so keys and clicks can be routed to
    /// the right store.
    weak var window: NSWindow? {
        didSet {
            // A URL event can arrive before SwiftUI has attached its window.
            if needsExternalPresentation, window != nil {
                DispatchQueue.main.async { [weak self] in self?.presentExternalLink() }
            }
        }
    }
    private var needsExternalPresentation = false
    /// Set by the command bar while it is open in this window.
    var onArrow: ((_ down: Bool) -> Void)?
    var onForget: (() -> Void)?

    /// The main window's store and, while it is open, the private one.
    static var all: [BrowserStore] { [shared] + (PrivateSession.shared.store.map { [$0] } ?? []) }

    static func store(for window: NSWindow?) -> BrowserStore? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID: UUID?
    /// The tab in the right-hand pane, when the view is split.
    @Published private(set) var splitID: UUID?
    @Published var focusedPane: Pane = .primary
    @Published var splitRatio = 0.5
    @Published var sidebarVisible = true {
        didSet {
            if sidebarVisible { sidebarPeek = false }
            sessionChanged()
        }
    }
    /// The hidden sidebar, slid out over the page because the pointer went to
    /// the window's left edge. Goes away again when the pointer leaves it.
    @Published private(set) var sidebarPeek = false
    /// The window fills the screen, so the frame round the page should go: a
    /// border is something a window has, and full screen is not a window.
    @Published var isFullScreen = false
    @Published var commandBar: CommandBarMode?
    @Published private(set) var switcher: Switcher?
    @Published var findVisible = false

    func showFind() {
        guard let focused else { return }
        findVisible = true
        focused.finder.focusRequest += 1
    }

    func dismissFind() {
        focused?.finder.dismiss()
        findVisible = false
        focused?.focus()
    }

    let downloads = Downloads()
    /// A private window reads the main window's history and learned shortcuts,
    /// so its command bar is just as useful, and never adds to either.
    private var ownHistory: History
    private var ownShortcuts: Shortcuts
    private(set) var history: History {
        get { isPrivateWindow ? BrowserStore.shared.ownHistory : ownHistory }
        set { if !isPrivateWindow { ownHistory = newValue } }
    }
    private(set) var shortcuts: Shortcuts {
        get { isPrivateWindow ? BrowserStore.shared.ownShortcuts : ownShortcuts }
        set { if !isPrivateWindow { ownShortcuts = newValue } }
    }
    private var recent = RecentOrder<UUID>()
    /// Tabs opened behind and not yet visited, kept in line for Ctrl-Tab.
    private var queuedBehind: Set<UUID> = []
    private var closed: [SavedTab] = []
    private var sessionSave: DispatchWorkItem?
    private var historySave: DispatchWorkItem?
    private var historyDirty = false
    private var sleepTimer: Timer?
    private var memoryPressure: DispatchSourceMemoryPressure?

    private struct SavedTab: Codable {
        var id: UUID
        var url: String?
        var title: String
        var pinned: Bool
        var group: UUID?
    }

    private struct Session: Codable {
        var tabs: [SavedTab]
        var selected: UUID?
        var split: UUID?
        var sidebarVisible: Bool
        var recent: [UUID]?
        var groups: [TabGroup]?
    }

    init(isPrivateWindow: Bool) {
        self.isPrivateWindow = isPrivateWindow
        if isPrivateWindow {
            ownHistory = History()
            ownShortcuts = Shortcuts()
        } else {
            ownHistory = Storage.load(History.self, from: "history.json") ?? History()
            ownShortcuts = Storage.load(Shortcuts.self, from: "shortcuts.json") ?? Shortcuts()
            restore()
            AdBlock.shared.onChange = {
                BrowserStore.all.forEach { $0.tabs.forEach { $0.refreshContentRules() } }
            }
            Task { await AdBlock.shared.prepare() }
        }
        KeyMonitor.shared.start()
        watchForIdleTabs()
    }

    // MARK: - Sleeping tabs

    private func watchForIdleTabs() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs(olderThan: TabSleep.idleLimit) }
        }
        sleepTimer?.tolerance = 10
        // The system saying it is short of memory is a strong signal — but a
        // soft `.warning` is common and fires for the whole machine, not Drift,
        // so it must not override a user who turned tab sleeping (and the memory
        // budget) off: there it falls back to the normal rules, which do nothing
        // when sleeping is off. A `.critical` is imminent exhaustion, where a
        // crash would lose every tab, so there idle tabs are given back anyway.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                FaviconCache.shared.trim()
                let critical = self.memoryPressure?.data.contains(.critical) ?? false
                self.sleepIdleTabs(olderThan: TabSleep.pressureLimit, force: critical)
            }
        }
        source.resume()
        memoryPressure = source
    }

    deinit {
        sleepTimer?.invalidate()
        memoryPressure?.cancel()
        sessionSave?.cancel()
        historySave?.cancel()
    }

    /// `force` is the menu command: it skips the clock, and the switch, but
    /// still leaves alone a tab that is playing or being written in.
    func sleepIdleTabs(olderThan limit: TimeInterval, force: Bool = false) {
        guard force || TabSleep.enabled else { return }
        let now = Date()
        for tab in tabs where !tab.isAsleep {
            let idle = now.timeIntervalSince(tab.lastActive)
            guard TabSleep.shouldSleep(idleFor: idle, limit: limit, isVisible: isVisible(tab), isLoading: tab.isLoading, activity: .init())
            else { continue }
            tab.activity { [weak self, weak tab] activity in
                MainActor.assumeIsolated {
                    guard let self, let tab, !tab.isAsleep,
                          self.tabs.contains(where: { $0 === tab }) else { return }
                    // Asked again with the answer in hand, since the tab may
                    // have been chosen while the page was being asked.
                    let idle = Date().timeIntervalSince(tab.lastActive)
                    if TabSleep.shouldSleep(idleFor: idle, limit: limit, isVisible: self.isVisible(tab), isLoading: tab.isLoading, activity: activity) {
                        tab.sleep()
                    }
                }
            }
        }
    }

    // MARK: - Leaving and returning to the app

    /// Switching to another app can hide the page as surely as switching tabs
    /// does, and then a playing video follows the user there too, and comes
    /// home when they are back. Only when the window really goes out of sight,
    /// though: covered, minimised, or on a Space they have left. A click on
    /// another screen makes another app active and leaves the window in plain
    /// view, and the video should stay where it is.
    func applicationActiveChanged(_ active: Bool) { windowSightChanged() }

    /// Whether the window was last seen in sight, as far as picture in
    /// picture is concerned.
    private var windowInSight = true
    private var sightCheck: DispatchWorkItem?
    /// Set while the window animates in or out of full screen, when it passes
    /// through being out of sight on its way to the other Space.
    var fullScreenTransition = false {
        didSet {
            guard fullScreenTransition != oldValue else { return }
            if !fullScreenTransition { return windowSightChanged() }
            // A transition that fails says nothing at its end.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.fullScreenTransition = false }
            }
        }
    }

    /// The window's occlusion changed, or might have. Going out of sight is
    /// believed only if it lasts: a Space switch covers the window for a
    /// moment on the way.
    func windowSightChanged() {
        sightCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleSight() }
        }
        sightCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + (isWindowInSight ? 0 : 0.4), execute: check)
    }

    private var isWindowInSight: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func settleSight() {
        guard !fullScreenTransition, window != nil else { return }
        let inSight = isWindowInSight
        guard inSight != windowInSight else { return }
        windowInSight = inSight
        guard PictureInPicture.automatic else { return }
        for tab in [selected, split].compactMap({ $0 }) {
            tab.pictureInPicture(inSight ? .tabShown : .tabHidden)
        }
    }

    // MARK: - Full screen inside the window

    /// The tab whose page has gone full screen, while it is the one in front.
    @Published private(set) var fullscreenTab: Tab?
    /// Whether the window went full screen for the page, and so should come
    /// back when the page is done.
    private var windowFullScreenForPage = false

    func pageFullscreenChanged(_ tab: Tab) {
        if tab.isPageFullscreen {
            guard isVisible(tab) else { tab.exitPageFullscreen(); return }
            fullscreenTab = tab
            // The window takes the screen too, as Arc's does, unless it has it
            // already. A window with no title bar (the test's) is left alone.
            if let window, window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) {
                windowFullScreenForPage = true
                window.toggleFullScreen(nil)
            }
        } else if fullscreenTab === tab {
            fullscreenTab = nil
            // Coming out of full screen re-parents the page's web view into the
            // framed layout, and re-parenting an NSView drops its first-responder
            // status — so the page stops getting keystrokes (a video's space,
            // arrow keys, j/k/l) until it is clicked. Hand focus back.
            if windowFullScreenForPage {
                windowFullScreenForPage = false
                // The window is also animating out of macOS full screen, and it
                // resets the first responder when that finishes — so focusing now
                // would not stick. Wait for the exit to complete (see
                // windowDidExitFullScreen).
                focusAfterWindowExit = tab
                if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            } else {
                // No window transition: restore focus once the view has settled.
                DispatchQueue.main.async { tab.restorePageKeyboardFocus() }
            }
        }
    }

    /// The tab whose page just left full screen, waiting for the window to
    /// finish animating out of macOS full screen before it is given focus back.
    private var focusAfterWindowExit: Tab?

    /// The window has finished leaving macOS full screen. If a page just left
    /// full screen with it, the page's web view can take focus again now that
    /// the window has stopped resetting the first responder.
    func windowDidExitFullScreen() {
        guard let tab = focusAfterWindowExit else { return }
        focusAfterWindowExit = nil
        DispatchQueue.main.async { tab.restorePageKeyboardFocus() }
    }

    /// The window is leaving full screen by the user's hand: the page comes
    /// out with it, and does not drag the window back.
    func windowLeavingFullScreen() {
        windowFullScreenForPage = false
        fullscreenTab?.exitPageFullscreen()
    }

    /// The picture-in-picture window's "back to the tab" button. WebKit only
    /// puts the video back inline; showing the tab is the browser's job.
    func returnedFromPictureInPicture(_ tab: Tab) {
        if !isVisible(tab) { select(tab) }
        surfaceWindow()
        // Coming forward from behind another app: the newer call names the app
        // in front, which the system takes as the click on its window that it
        // was; the older one is the fallback.
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            NSRunningApplication.current.activate(from: front, options: [.activateIgnoringOtherApps])
        }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        // Still refused: asking Launch Services to open Drift is honoured
        // where a direct request is not, as an open is trusted to be the
        // user's doing. Failing even that, the Dock icon asks for the click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak tab] in
            tab?.note("pip", "after asking directly, active: \(NSApp.isActive)")
            guard !NSApp.isActive else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    tab?.note("pip", "after asking Launch Services (\(error?.localizedDescription ?? "no error")), active: \(NSApp.isActive)")
                    if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
                }
            }
        }
    }

    // MARK: - Sidebar peek

    /// `x` is the pointer's distance from the window's left edge.
    func pointerMoved(x: CGFloat) {
        guard !sidebarVisible else { return }
        if !sidebarPeek, x <= 3 {
            sidebarPeek = true
        } else if sidebarPeek, x > Design.sidebarWidth + 24 {
            // A margin past the panel's edge, so grazing it does not dismiss.
            sidebarPeek = false
        }
    }

    /// While a popover hangs off the peeking sidebar, the pointer leaving the
    /// panel for the popover must not put the panel away, taking the popover
    /// with it. Released, the panel goes if the pointer is no longer over it.
    var peekHeld = false {
        didSet { if !peekHeld, sidebarPeek, !pointerOverSidebar { sidebarPeek = false } }
    }

    func endPeek() {
        guard !peekHeld else { return }
        sidebarPeek = false
    }

    /// A tab picked up to be dragged, from the sidebar peeking out or not.
    /// The sidebar stays until the mouse button is let go: as a drag starts,
    /// the pointer counts as having left the panel, and a peeking sidebar
    /// would slide away with the group the tab was on its way to, leaving it
    /// to be dropped on the page. What the drag carries is returned.
    func pickUp(_ tab: Tab) -> TabDrag {
        peekHeld = true
        dragWatch?.invalidate()
        let watch = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                self?.peekHeld = false
            }
        }
        // Common modes, so it is heard while AppKit runs the drag.
        RunLoop.main.add(watch, forMode: .common)
        dragWatch = watch
        return TabDrag(id: tab.id)
    }

    private var dragWatch: Timer?

    private var pointerOverSidebar: Bool {
        guard let window else { return false }
        let x = window.convertPoint(fromScreen: NSEvent.mouseLocation).x
        return x >= 0 && x <= Design.sidebarWidth + 24
    }

    // MARK: - Lookup

    func tab(_ id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    var selected: Tab? { tab(selectedID) }
    var split: Tab? { tab(splitID) }
    var focused: Tab? { focusedPane == .secondary ? (split ?? selected) : selected }

    var pinnedTabs: [Tab] { tabs.filter(\.isPinned) }
    var regularTabs: [Tab] { tabs.filter { !$0.isPinned } }
    /// Sidebar order, which is also what Cmd-1…9 count along: pinned tabs,
    /// then each group's, then the rest.
    var orderedTabs: [Tab] { pinnedTabs + groups.flatMap { tabs(in: $0.id) } + ungroupedTabs }

    // MARK: - Tab groups

    @Published private(set) var groups: [TabGroup] = []

    func tabs(in group: UUID) -> [Tab] { regularTabs.filter { $0.groupID == group } }
    var ungroupedTabs: [Tab] { regularTabs.filter { $0.groupID == nil } }
    func group(_ id: UUID?) -> TabGroup? { groups.first { $0.id == id } }

    @discardableResult
    func newGroup(named name: String, with tab: Tab) -> TabGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TabGroup(id: UUID(), name: trimmed.isEmpty ? "Group" : trimmed, color: .next(after: groups.map(\.color)), collapsed: false)
        groups.append(group)
        add(tab, to: group.id)
        return group
    }

    /// Into a group. A pinned tab is unpinned: pinned tabs stand apart.
    func add(_ tab: Tab, to group: UUID) {
        guard self.group(group) != nil else { return }
        if tab.isPinned { tab.isPinned = false }
        tab.groupID = group
        groupsChanged()
    }

    func removeFromGroup(_ tab: Tab) {
        tab.groupID = nil
        groupsChanged()
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        sessionChanged()
    }

    func setColor(_ color: GroupColor, of id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].color = color
        sessionChanged()
    }

    /// Expanded or collapsed: in the sidebar, and in Ctrl-Tab as tabs or a stack.
    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].collapsed = collapsed
        sessionChanged()
    }

    /// The group goes; its tabs stay, in no group.
    func ungroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        groupsChanged()
    }

    func closeGroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { close(tab) }
    }

    /// A group with no tabs left goes too.
    private func groupsChanged() {
        let used = Set(tabs.compactMap(\.groupID))
        for tab in tabs where tab.groupID.map({ id in !groups.contains { $0.id == id } }) == true { tab.groupID = nil }
        groups.removeAll { !used.contains($0.id) }
        objectWillChange.send()
        sessionChanged()
    }

    // MARK: - Private browsing

    /// Cookies, caches and site storage for the private window: in memory,
    /// shared between its tabs so a login carries from one to the next, and let
    /// go of when the window closes. The next private window starts clean.
    private var privateStore: WKWebsiteDataStore?

    func privateDataStore() -> WKWebsiteDataStore {
        if let privateStore { return privateStore }
        let fresh = WKWebsiteDataStore.nonPersistent()
        privateStore = fresh
        return fresh
    }

    /// Closes every tab and lets go of the private cookies and storage. What
    /// closing the private window does.
    func endSession() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        memoryPressure?.cancel()
        memoryPressure = nil
        tabs.forEach(close)
        privateStore = nil
    }

    func isVisible(_ tab: Tab) -> Bool { tab.id == selectedID || tab.id == splitID }

    // MARK: - Selecting

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        let previous = focused
        if let fullscreenTab, fullscreenTab !== tab { fullscreenTab.exitPageFullscreen() }
        previous?.takeThumbnail()
        previous?.lastActive = Date()
        tab.lastActive = Date()

        if tab.id == selectedID {
            focusedPane = .primary
        } else if tab.id == splitID {
            focusedPane = .secondary
        } else if splitID != nil, focusedPane == .secondary {
            splitID = tab.id
        } else {
            selectedID = tab.id
            focusedPane = .primary
        }

        recent.touch(tab.id)
        queuedBehind.remove(tab.id)
        findVisible = false
        sessionChanged()
        if previous?.id != tab.id, !tab.isPrivate {
            // A private tab is never mentioned to extensions, in either role.
            Extensions.shared.controller.didActivateTab(tab, previousActiveTab: previous)
        }
        // A video left playing follows the user out of its tab, and goes back
        // in when they return.
        if PictureInPicture.automatic {
            if let previous, !isVisible(previous) { previous.pictureInPicture(.tabHidden) }
            tab.pictureInPicture(.tabShown)
        }
        DispatchQueue.main.async { tab.focus() }
        tab.sampleTint(after: 0.2)
    }

    func selectIndex(_ index: Int) {
        let order = orderedTabs
        guard !order.isEmpty else { return }
        // Nine is "the last tab", however many there are.
        select(order[index >= 8 ? order.count - 1 : min(index, order.count - 1)])
    }

    func selectAdjacent(_ step: Int) {
        let order = orderedTabs
        guard let current = focused, let index = order.firstIndex(where: { $0.id == current.id }) else { return }
        select(order[(index + step + order.count) % order.count])
    }

    // MARK: - Opening and closing

    @discardableResult
    func newTab(_ url: URL, inBackground: Bool = false, pinned: Bool = false, isPrivate: Bool = false) -> Tab {
        // Everything opened in the private window is private, whoever asks.
        let isPrivate = isPrivate || isPrivateWindow
        let tab = Tab(url: url, isPinned: pinned && !isPrivate, isPrivate: isPrivate)
        tab.store = self
        insert(tab, after: focused)
        if inBackground {
            // Start it loading now; being off screen is no reason to wait.
            tab.materialize()
            openedBehind(tab)
            queueForSwitcher(tab)
        } else {
            select(tab)
        }
        sessionChanged()
        return tab
    }

    // MARK: - A word that something happened

    /// Shown for a moment when something happens that nothing else shows. A
    /// tab opened behind the current one while the sidebar is away: with no
    /// new row appearing, a Command-click looks like it did nothing, so this
    /// says it did, and is a way to that tab. A link copied: the clipboard
    /// shows nothing either.
    struct Notice: Equatable {
        let text: String
        let symbol: String
        /// Where a click on it goes, if anywhere.
        var tabID: UUID?
    }

    @Published private(set) var notice: Notice?
    private var noticeTimer: DispatchWorkItem?

    private func openedBehind(_ tab: Tab) {
        guard !sidebarVisible else { return }
        show(Notice(text: "Opened behind: \(tab.url.map(Address.displayHost) ?? "new tab")", symbol: "plus.rectangle.on.rectangle", tabID: tab.id), for: 2.5)
    }

    func copyLink(of tab: Tab) {
        guard let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show(Notice(text: "Link copied", symbol: "link"), for: 1.5)
    }

    private func show(_ notice: Notice, for seconds: Double) {
        self.notice = notice
        noticeTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    func dismissNotice() {
        noticeTimer?.cancel()
        notice = nil
    }

    private func insert(_ tab: Tab, after opener: Tab?) {
        // Beside the tab it came from, when that is the same kind of tab.
        if let opener, !opener.isPinned, opener.isPrivate == tab.isPrivate,
           let index = tabs.firstIndex(where: { $0.id == opener.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        Extensions.shared.controller.didOpenTab(tab)
    }

    /// A window the page asked for. WebKit supplies the configuration and
    /// expects the web view back.
    /// `inBackground` for a page opened by a Command- or middle-click that
    /// the site turned into `window.open`, as YouTube and most other apps
    /// do: the click meant "open behind", whatever the site does with it.
    func openPopup(configuration: WKWebViewConfiguration, from opener: Tab, inBackground: Bool = false) -> WKWebView {
        // The configuration WebKit hands over carries the opener's data store,
        // so the new tab is private exactly when the opener is.
        let tab = Tab(url: nil, isPrivate: opener.isPrivate || isPrivateWindow)
        tab.store = self
        let view = tab.materialize(configuration: configuration)
        insert(tab, after: opener)
        if inBackground {
            openedBehind(tab)
            queueForSwitcher(tab)
        } else {
            select(tab)
        }
        return view
    }

    /// A tab opened behind is next in line for Ctrl-Tab: a Command-click and
    /// then Ctrl-Tab goes straight to it.
    private func queueForSwitcher(_ tab: Tab) {
        recent.queue(tab.id, behind: queuedBehind)
        queuedBehind.insert(tab.id)
    }

    // MARK: - Mouse buttons

    /// The side buttons on a mouse: back and forward, as every browser has them.
    /// Returns whether the button meant something.
    func mouseButton(_ number: Int) -> Bool {
        switch number {
        case 3: focused?.goBack(); return true
        case 4: focused?.goForward(); return true
        default: return false
        }
    }

    /// A link handed over by the system, as the default browser gets them.
    func open(external url: URL) {
        commandBar = nil
        cancelSwitcher()
        newTab(url)
        needsExternalPresentation = true
        presentExternalLink()
    }

    private func presentExternalLink() {
        guard needsExternalPresentation, window != nil else { return }
        needsExternalPresentation = false
        surfaceWindow()
        NSApp.activate(ignoringOtherApps: true)
        // Activation may switch Spaces on its own; only after that has had
        // its chance is the window fetched to where the user is looking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.surfaceWindow(fetching: true) }
    }

    /// Makes sure the window can actually be seen: un-minimised, on a screen
    /// that still exists, in front, and, when asked, on the Space the user is
    /// looking at. A window left on a display that was unplugged, or on
    /// another Space when the system is set not to follow windows, is "open"
    /// with nothing to look at, which was the report: Drift in front, no window.
    func surfaceWindow(fetching: Bool = false) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        let screens = NSScreen.screens
        if !window.styleMask.contains(.fullScreen),
           window.screen == nil || !screens.contains(where: { $0.visibleFrame.intersects(window.frame) }),
           let home = NSScreen.main ?? screens.first {
            var frame = window.frame
            frame.size.width = min(frame.width, home.visibleFrame.width)
            frame.size.height = min(frame.height, home.visibleFrame.height)
            frame.origin.x = home.visibleFrame.midX - frame.width / 2
            frame.origin.y = home.visibleFrame.midY - frame.height / 2
            window.setFrame(frame, display: true)
        }
        if fetching, !window.isOnActiveSpace, !window.styleMask.contains(.fullScreen) {
            // `.moveToActiveSpace` is honoured when the app is next activated,
            // and the window server acts on it a moment after that, so the
            // behaviour has to stay on across the activation. Putting it back
            // on the next line, as this did, undid it before it took.
            let usual = window.collectionBehavior
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
                window?.collectionBehavior = usual
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // A private tab cannot be reopened: remembering it would be the leak.
        if !tab.isPrivate, let url = tab.url {
            closed.append(SavedTab(id: tab.id, url: url.absoluteString, title: tab.title, pinned: tab.isPinned, group: tab.groupID))
            if closed.count > 25 { closed.removeFirst() }
        }
        tabs.remove(at: index)
        recent.remove(tab.id)
        queuedBehind.remove(tab.id)
        if tab.groupID != nil { groupsChanged() }
        Extensions.shared.controller.didCloseTab(tab, windowIsClosing: false)
        // A page in full screen goes with its tab; the window comes back too.
        if fullscreenTab === tab {
            fullscreenTab = nil
            if windowFullScreenForPage {
                windowFullScreenForPage = false
                if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
        tab.sleep()

        // Whether closing this tab hands the screen to a different one, which
        // should then pull its video back out of Picture in Picture.
        let closingSelected = selectedID == tab.id

        if tab.id == splitID {
            splitID = nil
            focusedPane = .primary
        } else if tab.id == selectedID {
            if let promoted = splitID {
                // The right pane's tab takes over the window.
                selectedID = promoted
                splitID = nil
                focusedPane = .primary
            } else {
                let next = recent.ordered(existing: tabs.map(\.id)).first
                selectedID = next
                if let next { recent.touch(next) }
            }
        }
        // The tab now on screen returns from Picture in Picture, as selecting
        // it would — close() sets selectedID directly, bypassing select(), so
        // the same thing has to be done here.
        if closingSelected, PictureInPicture.automatic, let now = focused {
            now.pictureInPicture(.tabShown)
        }
        sessionChanged()
        if let now = focused { DispatchQueue.main.async { now.focus() } }
    }

    func closeOthers(keeping tab: Tab) {
        for other in tabs where other.id != tab.id && !other.isPinned { close(other) }
    }

    func reopenClosed() {
        guard let last = closed.popLast(), let url = last.url.flatMap(URL.init(string:)) else { return }
        let tab = newTab(url, pinned: last.pinned)
        // Back into its group, if the group is still there.
        if let group = last.group, self.group(group) != nil { add(tab, to: group) }
    }

    func togglePin(_ tab: Tab) {
        guard !tab.isPrivate else { return }
        tab.isPinned.toggle()
        if tab.isPinned, tab.groupID != nil {
            tab.groupID = nil
            groupsChanged()
        }
        objectWillChange.send()
        sessionChanged()
    }

    /// Drag-to-reorder within the unpinned list.
    func move(_ tab: Tab, before target: Tab) {
        guard tab.id != target.id, tab.isPrivate == target.isPrivate,
              let from = tabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0.id == target.id }) ?? tabs.count
        tab.isPinned = target.isPinned
        // Dropped among a group's tabs, it joins the group; among the rest, it leaves.
        let regrouped = tab.groupID != target.groupID
        tab.groupID = target.isPinned ? nil : target.groupID
        tabs.insert(tab, at: to)
        if regrouped { groupsChanged() }
        sessionChanged()
    }

    // MARK: - Command bar

    /// `typed` is what was in the bar when the row was chosen, which is what
    /// the choice gets remembered against.
    func run(_ suggestion: Suggestion, typed: String = "") {
        let mode = commandBar ?? .newTab
        commandBar = nil
        // What is typed and chosen privately teaches the command bar nothing.
        if !isPrivateWindow { learn(suggestion, typed: typed) }
        switch suggestion.action {
        case .switchTo(let id):
            if let tab = tab(id) {
                if mode == .split { putInSplit(tab) } else { select(tab) }
            }
        case .open(let url):
            switch mode {
            case .current:
                if let focused { focused.load(url); DispatchQueue.main.async { focused.focus() } } else { newTab(url) }
            case .newTab:
                newTab(url)
            case .split:
                let tab = newTab(url, inBackground: true)
                putInSplit(tab)
            }
        }
    }

    private func learn(_ suggestion: Suggestion, typed: String) {
        // A search is what Return does anyway; there is nothing to learn from it.
        guard suggestion.kind != .search else { return }
        let destination: URL?
        let title: String
        switch suggestion.action {
        case .open(let url):
            destination = url
            title = suggestion.kind == .address ? "" : suggestion.title
        case .switchTo(let id):
            destination = tab(id)?.url
            title = tab(id)?.title ?? ""
        }
        guard let destination else { return }
        shortcuts.learn(typed: typed, url: destination, title: title)
        Storage.save(shortcuts, to: "shortcuts.json")
    }

    /// Shift-Delete on a row: never offer that page again, from memory or history.
    func forget(_ suggestion: Suggestion) {
        guard !isPrivateWindow, case .open(let url) = suggestion.action else { return }
        shortcuts.forget(url: url.absoluteString)
        history.forget(url: url.absoluteString)
        Storage.save(shortcuts, to: "shortcuts.json")
        historyChanged()
        objectWillChange.send()
    }

    func dismissCommandBar() {
        commandBar = nil
        focused?.focus()
    }

    // MARK: - Split view

    func toggleSplit() {
        if splitID != nil {
            splitID = nil
            focusedPane = .primary
            sessionChanged()
            return
        }
        guard selectedID != nil else { return }
        // The tab you were last on is the likeliest thing to want alongside.
        let candidate = recent.ordered(existing: tabs.map(\.id)).first { $0 != selectedID }
        if let candidate = tab(candidate) {
            putInSplit(candidate)
        } else {
            commandBar = .split
        }
    }

    func putInSplit(_ tab: Tab) {
        guard tab.id != selectedID else { return }
        splitID = tab.id
        focusedPane = .secondary
        recent.touch(tab.id)
        sessionChanged()
        DispatchQueue.main.async { tab.focus() }
    }

    // MARK: - Ctrl-Tab

    func advanceSwitcher(backwards: Bool) {
        if var open = switcher {
            open.index = SwitcherGrid.step(from: open.index, count: open.entries.count, backwards: backwards)
            switcher = open
            return
        }
        let order = recent.ordered(existing: tabs.map(\.id))
        guard order.count > 1 else { return }
        focused?.takeThumbnail()
        commandBar = nil
        var fresh = Switcher(recent: order, openGroup: focused?.groupID)
        layOut(&fresh)
        // Opens already pointing at the card holding the previous tab, so a
        // quick tap of Ctrl-Tab flips between the last two.
        fresh.index = SwitcherLayout.openingIndex(entries: fresh.entries, recent: order, groupOf: groupOfTab, backwards: backwards)
        switcher = fresh
    }

    private var groupOfTab: [UUID: UUID] {
        Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in tab.groupID.map { (tab.id, $0) } })
    }

    private func layOut(_ open: inout Switcher) {
        open.recent.removeAll { tab($0) == nil }
        open.sections = SwitcherLayout.sections(
            recent: open.recent, groupOf: groupOfTab, groups: groups,
            mode: SwitcherGrouping.current, openGroup: open.openGroup
        )
    }

    /// The pointer over a card in the overlay: that becomes the highlighted
    /// one, so letting go of Control lands there.
    func hoverSwitcher(_ index: Int) {
        guard var open = switcher, open.entries.indices.contains(index), open.index != index else { return }
        open.index = index
        switcher = open
    }

    /// Up and Down in the overlay: a row at a time.
    func moveSwitcherRow(down: Bool) {
        guard var open = switcher else { return }
        open.index = SwitcherGrid.jumpRow(from: open.index, rowLengths: SwitcherLayout.rowLengths(open.sections), down: down)
        switcher = open
    }

    /// W with the overlay up (Control is already held): close the highlighted tab and stay in the
    /// overlay, so a run of tabs can be cleared without leaving it. The
    /// highlight moves to whatever slides into the gap. A stack is a whole
    /// group, too much for one key; W leaves it be.
    func closeSwitcherSelection() {
        guard var open = switcher, let id = open.litTab else {
            if switcher?.lit != nil { NSSound.beep() }
            return
        }
        if let tab = tab(id) { close(tab) }
        layOut(&open)
        guard !open.entries.isEmpty else {
            switcher = nil
            return
        }
        open.index = min(open.index, open.entries.count - 1)
        switcher = open
    }

    /// G with the overlay up: a stacked group opens out into its tabs, or the
    /// group of the lit tab folds back into a stack. The same switch as the
    /// group's arrow in the sidebar.
    func toggleSwitcherGroup() {
        guard var open = switcher, let lit = open.lit else { return }
        let groupID: UUID?
        let opening: Bool
        switch lit {
        case .group(let id): groupID = id; opening = true
        case .tab(let id): groupID = tab(id)?.groupID; opening = false
        }
        guard let groupID, group(groupID) != nil else { return }
        setCollapsed(groupID, !opening)
        if !opening, open.openGroup == groupID { open.openGroup = nil }
        layOut(&open)
        // The light stays on what was toggled: its stack, or its first tab,
        // in its own row when groups have rows.
        let sectionStart = open.sections.firstIndex { $0.group == groupID }.map { open.sections.prefix($0).reduce(0) { $0 + $1.entries.count } }
        let anywhere = open.entries.firstIndex { entry in
            switch entry {
            case .group(let id): return id == groupID
            case .tab(let id): return tab(id)?.groupID == groupID
            }
        }
        open.index = sectionStart ?? anywhere ?? 0
        switcher = open
    }

    func commitSwitcher() {
        guard let open = switcher else { return }
        switcher = nil
        switch open.lit {
        case .tab(let id)?:
            if let tab = tab(id) { select(tab) }
        case .group(let id)?:
            // A stack lands on the group's latest tab.
            if let latest = open.recent.lazy.compactMap({ self.tab($0) }).first(where: { $0.groupID == id }) { select(latest) }
        case nil:
            break
        }
    }

    func cancelSwitcher() { switcher = nil }

    // MARK: - History

    func recordVisit(url: URL, title: String) {
        guard !isPrivateWindow else { return }
        history.record(url: url, title: title)
        historyChanged()
    }

    func retitle(url: URL, title: String) {
        guard !isPrivateWindow, !title.isEmpty,
              let entry = history.entries[url.absoluteString], entry.title != title else { return }
        history.retitle(url: url, title: title)
        historyChanged()
    }

    func clearHistory() {
        history.clear()
        shortcuts.clear()
        Storage.save(shortcuts, to: "shortcuts.json")
        objectWillChange.send()
        historyChanged()
    }

    private func historyChanged() {
        historyDirty = true
        historySave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isPrivateWindow, self.historyDirty {
                Storage.saveAsync(self.history, to: "history.json")
                self.historyDirty = false
            }
        }
        historySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Session

    /// Saves soon. Called on anything that changes what a relaunch should bring
    /// back; coalesced, because a page load fires it several times over.
    func sessionChanged() {
        // The private window has no session to save: it does not come back.
        guard !isPrivateWindow else { return }
        sessionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        guard !isPrivateWindow else { return }
        sessionSave?.cancel()
        historySave?.cancel()
        saveSession()
        if historyDirty {
            Storage.saveAsync(history, to: "history.json")
            historyDirty = false
        }
        Storage.flush()
    }

    private func saveSession() {
        guard !isPrivateWindow else { return }
        // Private tabs are not written down, so they do not come back at the
        // next launch, and the file never names a page opened privately.
        let kept = tabs.filter { !$0.isPrivate }
        let keptIDs = Set(kept.map(\.id))
        let order = recent.ordered(existing: kept.map(\.id))
        let session = Session(
            tabs: kept.map { SavedTab(id: $0.id, url: $0.url?.absoluteString, title: $0.title, pinned: $0.isPinned, group: $0.groupID) },
            selected: selectedID.flatMap { keptIDs.contains($0) ? $0 : nil } ?? order.first,
            split: splitID.flatMap { keptIDs.contains($0) ? $0 : nil },
            sidebarVisible: sidebarVisible,
            recent: order,
            groups: groups.filter { group in kept.contains { $0.groupID == group.id } }
        )
        Storage.saveAsync(session, to: "session.json")
    }

    private func restore() {
        guard let session = Storage.load(Session.self, from: "session.json") else { return }
        tabs = session.tabs.compactMap { saved in
            guard let url = saved.url.flatMap(URL.init(string:)) else { return nil }
            let tab = Tab(id: saved.id, url: url, title: saved.title, isPinned: saved.pinned)
            tab.groupID = saved.group
            tab.store = self
            return tab
        }
        groups = session.groups ?? []
        let used = Set(tabs.compactMap(\.groupID))
        groups.removeAll { !used.contains($0.id) }
        for tab in tabs where tab.groupID.map({ id in !groups.contains { $0.id == id } }) == true { tab.groupID = nil }
        for id in (session.recent ?? []).reversed() where tab(id) != nil { recent.touch(id) }
        selectedID = tab(session.selected)?.id ?? tabs.first?.id
        splitID = session.split.flatMap { $0 == selectedID ? nil : tab($0)?.id }
        sidebarVisible = session.sidebarVisible
        if let selectedID { recent.touch(selectedID) }
    }
}
