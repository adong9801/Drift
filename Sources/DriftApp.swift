import SwiftUI

@main
struct DriftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BrowserStore.shared

    var body: some Scene {
        Window("Drift", id: "browser") {
            BrowserWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 880)
        .commands { BrowserCommands() }

        // Private browsing gets a window to itself. It is opened from the File
        // menu, never at launch, and closing it ends the private session.
        Window("Private", id: "private") {
            PrivateWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

/// The private window's contents: whatever store the private session has, and
/// nothing once it has ended.
struct PrivateWindow: View {
    @ObservedObject private var session = PrivateSession.shared

    var body: some View {
        Group {
            if let store = session.store {
                BrowserWindow(store: store)
                    // A new session is a new window's worth of state.
                    .id(ObjectIdentifier(store))
                    // Dark, always: the quickest way to tell the two windows apart.
                    .preferredColorScheme(.dark)
            } else {
                Design.chrome
            }
        }
        .onAppear { session.begin() }
    }
}

/// The parts of app life SwiftUI has no hook for: links arriving from other
/// apps, and a last save on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { BrowserStore.shared.open(external: url) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PiPInstant.install()
        Task { @MainActor in
            await PrivateRuleList.shared.prepare()
            await Extensions.shared.start()
            MemoryMonitor.shared.start()
            PiPDrag.shared.startIfWanted()
        }
    }

    /// Pointer moves are not delivered to a window unless it asks, and the
    /// hidden sidebar needs them to know the pointer reached the left edge.
    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
        MainActor.assumeIsolated {
            BrowserStore.all.forEach { $0.applicationActiveChanged(true) }
            // Access may have been granted in System Settings in the meantime.
            PiPDrag.shared.startIfWanted()
            // A click on the Dock icon that brings the app forward but shows no
            // window: the window is on another Space the system chose not to
            // switch to, or off any screen. Given a moment for the system's
            // own Space switch, if that did not happen the window comes here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard NSApp.isActive else { return }
                // The plain question: is there any Drift window the user can
                // actually see? A window can be key and main and still be on
                // another Space, which is what "active, but no window" was.
                let inSight = NSApp.windows.contains {
                    $0.isVisible && $0.isOnActiveSpace && !$0.isMiniaturized && $0.contentView != nil && $0.frame.width > 200
                }
                guard !inSight else { return }
                BrowserStore.shared.surfaceWindow(fetching: true)
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { BrowserStore.all.forEach { $0.applicationActiveChanged(false) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { BrowserStore.shared.saveNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The menu bar, which is also where every shortcut lives. Ctrl-Tab is the
/// exception; see `KeyMonitor`.
struct BrowserCommands: Commands {
    /// The menu bar speaks to whichever window is in front.
    @ObservedObject private var router = WindowRouter.shared
    @ObservedObject private var extensions = Extensions.shared
    @Environment(\.openWindow) private var openWindow

    private var store: BrowserStore { router.active }

    var body: some Commands {
        // Ahead of the stock Close item, so Cmd-W closes a tab, not the window.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.commandBar = .newTab }
                .keyboardShortcut("t")
            Button("New Private Window") {
                // Opens it, or brings it forward, ready for an address.
                let session = PrivateSession.shared.begin()
                openWindow(id: "private")
                if session.tabs.isEmpty { session.commandBar = .newTab }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Location\u{2026}") { store.commandBar = .current }
                .keyboardShortcut("l")
            Button("Reopen Closed Tab") { store.reopenClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            // Closes whatever is on top: the command bar, then an extension's
            // popup, and only then the tab underneath them.
            Button("Close Tab") {
                if store.commandBar != nil {
                    store.dismissCommandBar()
                } else if Extensions.shared.closeOpenPopup() {
                    return
                } else if let tab = store.focused {
                    store.close(tab)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }

        CommandGroup(after: .textEditing) {
            Button("Find\u{2026}") { store.showFind() }
                .keyboardShortcut("f")
                .disabled(store.focused == nil)
            Button("Find Next") { store.focused?.finder.next() }
                .keyboardShortcut("g")
                .disabled(store.focused == nil)
            Button("Find Previous") { store.focused?.finder.next(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store.focused == nil)
            Button("Copy Page Link") {
                if let tab = store.focused { store.copyLink(of: tab) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { store.sidebarVisible.toggle() }
                .keyboardShortcut("s")
            Button("Toggle Split View") { store.toggleSplit() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Reload Page") { store.focused?.reload() }
                .keyboardShortcut("r")
            Button("Zoom In") { store.focused?.zoom(by: 1.1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { store.focused?.zoom(by: 1 / 1.1) }
                .keyboardShortcut("-")
            Button("Actual Size") { store.focused?.zoom(by: nil) }
                .keyboardShortcut("0")
            Button("Web Inspector") { store.focused?.showInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Picture in Picture") { store.focused?.pictureInPicture(.toggle) }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("Picture in Picture When Leaving a Tab or Drift", isOn: Binding(
                get: { PictureInPicture.automatic },
                set: { PictureInPicture.automatic = $0 }
            ))
            Toggle("Drag Picture in Picture Anywhere", isOn: Binding(
                get: { PiPDrag.wanted },
                set: { on in
                    PiPDrag.wanted = on
                    if on { PiPDragPrompt.turnOn() } else { PiPDrag.shared.stop() }
                }
            ))
            Divider()
            Toggle("Dim Bright Pages in Dark Mode", isOn: Binding(
                get: { EyeComfort.dimsBrightPages },
                set: { EyeComfort.dimsBrightPages = $0 }
            ))
            Toggle("Dark Google Docs in Dark Mode", isOn: Binding(
                get: { DocsDark.enabled },
                set: { on in
                    DocsDark.enabled = on
                    BrowserStore.all.flatMap(\.tabs).forEach { $0.setDocsDark(on) }
                }
            ))
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { store.focused?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { store.focused?.goForward() }
                .keyboardShortcut("]")
            Divider()
            // The latest pages, newest first. The command bar searches all of it.
            ForEach(BrowserStore.shared.history.recent(limit: 15), id: \.url) { entry in
                Button(entry.title.isEmpty ? entry.url : String(entry.title.prefix(60))) {
                    if let url = URL(string: entry.url) { store.newTab(url) }
                }
            }
            Divider()
            Button("Clear History") { BrowserStore.shared.clearHistory() }
        }

        // Where extensions are reached while the sidebar is up. Each one's
        // popup opens at the window's corner, since there is no button to hang
        // it from; the top bar has the buttons when the sidebar is away.
        CommandMenu("Extensions") {
            ForEach(extensions.actionable) { record in
                Button(extensions.name(of: record)) { extensions.perform(record) }
            }
            if !extensions.actionable.isEmpty { Divider() }
            Button("Manage Extensions\u{2026}") { ExtensionManagerPanel.show() }
        }
        CommandMenu("Tabs") {
            Button("Next Tab") { store.selectAdjacent(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Tab") { store.selectAdjacent(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Pin or Unpin Tab") {
                if let tab = store.focused { store.togglePin(tab) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store.selectIndex(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Divider()
            Toggle("Put Unused Tabs to Sleep", isOn: Binding(
                get: { TabSleep.enabled },
                set: { TabSleep.enabled = $0 }
            ))
            Button("Sleep Other Tabs Now") { store.sleepIdleTabs(olderThan: 0, force: true) }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Make Drift the Default Browser") { DefaultBrowser.claim() }
            Button("Create Debugging Archive\u{2026}") { DebugArchivePrompt.show() }
            Button("Copy Diagnostics") {
                Task { @MainActor in
                    let report = await Extensions.shared.diagnostics()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    let alert = NSAlert()
                    alert.messageText = "Diagnostics copied"
                    alert.informativeText = "It lists the page\u{2019}s address, its media and field names, and recent extension errors. No field contents. Have a look before you paste it anywhere."
                    alert.runModal()
                }
            }
        }
    }
}


/// Asks what went wrong, then makes the archive and shows it in the Finder.
@MainActor
enum DebugArchivePrompt {
    static func show() {
        let alert = NSAlert()
        alert.messageText = "Create a debugging archive"
        alert.informativeText = "A zip goes on the Desktop with the open tabs and their addresses, what each page reported, pictures of the windows and pages, the extension log, and Drift\u{2019}s own lines from the system log. No cookies, passwords or page contents. Say what went wrong, in your own words:"
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 72))
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isRichText = false
        let scroll = NSScrollView(frame: field.frame)
        scroll.documentView = field
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let note = field.string
        Task { @MainActor in
            do {
                let zip = try await DebugArchive.create(note: note)
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            } catch {
                let failed = NSAlert(error: error)
                failed.messageText = "The archive could not be made"
                failed.runModal()
            }
        }
    }
}

/// The extension manager as a small window of its own, for the menu bar to
/// open when there is no puzzle-piece button on screen.
@MainActor
enum ExtensionManagerPanel {
    private static var panel: NSPanel?

    static func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: ExtensionManager(extensions: Extensions.shared))
        // The window follows the list as extensions come and go.
        controller.sizingOptions = [.preferredContentSize]
        let fresh = NSPanel(contentViewController: controller)
        fresh.styleMask = [.titled, .closable, .utilityWindow]
        fresh.title = "Extensions"
        fresh.isReleasedWhenClosed = false
        fresh.center()
        fresh.makeKeyAndOrderFront(nil)
        panel = fresh
    }
}

/// Turning on the free picture-in-picture drag: needs Accessibility access,
/// asked for once, with a word on what it is for.
@MainActor
enum PiPDragPrompt {
    static func turnOn() {
        if PiPDrag.hasAccess {
            PiPDrag.shared.startIfWanted()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Drift needs Accessibility access for this"
        alert.informativeText = "The picture-in-picture window is the system\u{2019}s, and it only leaves the corners while Command is held. To hold it for you, Drift has to see your mouse drags, which macOS allows only with Accessibility access.\n\nThat access lets an app watch all input, so grant it only if you are comfortable with that. Drift uses it for nothing but drags that start on the picture-in-picture window, and for putting that window back where you last left it.\n\nSystem Settings will open to Privacy & Security \u{203a} Accessibility; switch Drift on there, then come back."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            PiPDrag.wanted = false
            return
        }
        PiPDrag.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
