import AppKit
import WebKit
import ImageIO

/// One tab. Owns its web view, mirrors the bits of its state the interface
/// draws, and answers WebKit's questions about navigation and page dialogs.
///
/// A tab restored from the last session has no web view until it is first
/// shown. Thirty tabs at launch should cost thirty rows in a list, not thirty
/// web processes.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {

    let id: UUID
    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var favicon: NSImage?
    /// What Ctrl-Tab shows, kept as a JPEG. As a decoded image each one is a
    /// few megabytes, which with thirty tabs is real memory for pictures that
    /// are looked at for a second at a time. The switcher decodes them while it
    /// is open and lets them go after.
    @Published private(set) var thumbnailData: Data?
    var thumbnail: NSImage? { thumbnailData.flatMap(NSImage.init(data:)) }
    /// No web view behind it: never opened since launch, or put to sleep.
    @Published private(set) var isAsleep = true
    /// When it was last on screen. What sleeping is judged by.
    var lastActive = Date()
    /// Scroll position and back-forward list, held while asleep.
    private var savedState: Any?
    @Published var isPinned: Bool
    /// The colour along the top of the page, for the chrome to match.
    @Published var tint: PageTint?
    /// There is a video on the page, so the picture-in-picture button is worth showing.
    @Published var hasVideo = false

    weak var store: BrowserStore?
    private(set) var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var faviconHost: String?
    private var frameActivity: [String: TabSleep.Activity] = [:]
    /// Trouble the page has reported, for the debugging archive.
    fileprivate(set) var log = PageLog()

    func note(_ level: String, _ text: String) { log.add(level, text) }
    /// The page has an element in Drift's in-window full screen.
    @Published fileprivate(set) var isPageFullscreen = false
    private var editedFrame = false
    private var navigationGeneration = 0
    private var tintWork: DispatchWorkItem?
    private var thumbnailInFlight = false
    private var lastThumbnail = Date.distantPast
    let finder = PageFind()

    /// A private tab keeps its cookies and storage in memory, shared only with
    /// other private tabs, and leaves nothing on disk: no history, no learned
    /// shortcuts, no saved session, no cached icon. Extensions are not shown it.
    let isPrivate: Bool

    init(id: UUID = UUID(), url: URL?, title: String = "", isPinned: Bool = false, isPrivate: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        super.init()
        if let host = url?.host { favicon = FaviconCache.shared.cached(host: host) }
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let url { return Address.displayHost(url) }
        return "New Tab"
    }

    var isLive: Bool { webView != nil }

    // MARK: - Web view

    /// The web view, made on first use. `configuration` is only passed when
    /// WebKit itself asked for the tab (a popup), in which case WebKit insists
    /// its own configuration is used.
    @discardableResult
    func materialize(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }

        // An extension's own pages only work inside the configuration WebKit
        // made for that extension.
        let extensionPage = isPrivate ? nil : url.flatMap { Extensions.shared.configuration(forPageAt: $0) }
        let view = PageView(
            frame: .zero,
            configuration: configuration ?? extensionPage ?? Self.makeConfiguration(privateStore: isPrivate ? store?.privateDataStore() : nil)
        )
        // Popup configurations may share their controller with the opener.
        // Route messages using message.webView instead of capturing one tab.
        let scripts = view.configuration.userContentController
        scripts.removeScriptMessageHandler(forName: "driftActivity", contentWorld: Self.ownWorld)
        scripts.add(TabActivityBridge.shared, contentWorld: Self.ownWorld, name: "driftActivity")
        scripts.removeScriptMessageHandler(forName: "driftLog", contentWorld: Self.ownWorld)
        scripts.add(TabLogBridge.shared, contentWorld: Self.ownWorld, name: "driftLog")
        scripts.removeScriptMessageHandler(forName: "driftFullscreen", contentWorld: Self.ownWorld)
        scripts.add(TabFullscreenBridge.shared, contentWorld: Self.ownWorld, name: "driftFullscreen")
        scripts.removeScriptMessageHandler(forName: "driftPiP", contentWorld: Self.ownWorld)
        scripts.add(TabPiPBridge.shared, contentWorld: Self.ownWorld, name: "driftPiP")
        view.tab = self
        // What shows before the page has painted, and behind any page with
        // no background of its own: the window's colour, so a page waking in
        // a dark room does not arrive as a white sheet.
        view.underPageBackgroundColor = .windowBackgroundColor
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        webView = view
        finder.attach(view)
        isAsleep = false
        lastActive = Date()
        observe(view)

        if let savedState {
            // Waking up: back where it was, history and scroll position too.
            view.interactionState = savedState
            self.savedState = nil
        } else if configuration == nil, let url {
            // A popup loads itself; everything else starts from the saved address.
            view.load(URLRequest(url: url))
        }
        return view
    }

    /// Where Drift's own page scripts run, out of reach of the page's.
    static let ownWorld = WKContentWorld.world(name: "Drift")

    /// `privateStore` is the in-memory data store private tabs share. Given
    /// one, the page gets it instead of the profile, and no extensions.
    static func makeConfiguration(privateStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let privateStore { configuration.websiteDataStore = privateStore }
        // WebKit's own user agent stops short of naming a browser, and sites
        // that sniff for "Safari" serve it a degraded page. This completes it.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Nothing held back for a click. Requiring one for sound breaks sites
        // that open a video without a page load: on YouTube the click that
        // chose the video does not count, and it sits there until clicked again.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Picture in picture is built into WebKit on the Mac but off for
        // embedded web views, and the switch is not public. Checked first, so a
        // WebKit that drops it means no picture in picture rather than a crash.
        if configuration.preferences.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        // Inspect Element in the right-click menu, and the Web Inspector
        // itself. Off for embedded web views, and again the switch is private.
        if configuration.preferences.responds(to: Selector(("_setDeveloperExtrasEnabled:"))) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        Self.turnOffWebGPU(configuration.preferences)
        // In a world of its own, where the page's scripts cannot reach it.
        configuration.userContentController.addUserScript(WKUserScript(
            source: TabSleep.tracker,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.ownWorld
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: SiteQuirks.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.ownWorld
        ))
        // Script errors can only be heard in the page's world; they are passed
        // to Drift's as plain text.
        configuration.userContentController.addUserScript(WKUserScript(
            source: PageLog.captureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: PageLog.relayScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.ownWorld
        ))
        // Full screen kept inside the window; see PageFullscreen.
        configuration.userContentController.addUserScript(WKUserScript(
            source: PageFullscreen.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: PageFullscreen.relayScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.ownWorld
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: PictureInPicture.returnWatcher,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.ownWorld
        ))
        // What lets extensions see and act on this page. A private one only
        // once some extension has been let into private windows; even then
        // WebKit keeps the page from the extensions that have not.
        if privateStore == nil || Extensions.shared.anyAllowedInPrivate {
            configuration.webExtensionController = Extensions.shared.controller
        }
        if let list = AdBlock.shared.active {
            configuration.userContentController.add(list)
        }
        // Private tabs send YouTube no cookies; see PrivateRules.
        if privateStore != nil, let list = PrivateRuleList.shared.list {
            configuration.userContentController.add(list)
        }
        return configuration
    }

    /// WebGPU off. WebKit leaves a thread behind in its GPU process, with the
    /// graphics surfaces it holds, for every page that asked for a WebGPU
    /// adapter once that page's view is gone: a tab closed, or put to sleep
    /// and woken. Ad and fingerprinting scripts ask on page after page. After
    /// two days of browsing there were 5,336 such threads and 16,676 surfaces,
    /// the process could not make another, and video stopped playing on every
    /// site. Next to no site needs WebGPU; WebGL is untouched.
    ///
    /// The switch is one of WebKit's private feature flags, looked up by name;
    /// a WebKit without it leaves WebGPU as it is.
    static func turnOffWebGPU(_ preferences: WKPreferences) {
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        guard let feature = webGPUFeature, preferences.responds(to: setter),
              let implementation = class_getMethodImplementation(WKPreferences.self, setter) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(implementation, to: SetEnabled.self)(preferences, setter, false, feature)
    }

    private static let webGPUFeature: NSObject? = {
        let list = NSSelectorFromString("_features")
        guard (WKPreferences.self as AnyObject).responds(to: list),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return features.first { $0.value(forKey: "key") as? String == "WebGPUEnabled" }
    }()

    /// Brings this tab's blocking into line with the current switch and list.
    func refreshContentRules() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllContentRuleLists()
        if let list = AdBlock.shared.active { controller.add(list) }
        if isPrivate, let list = PrivateRuleList.shared.list { controller.add(list) }
    }

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = view.title ?? ""
                    if !self.isPrivate, let url = view.url { self.store?.retitle(url: url, title: self.title) }
                    Extensions.shared.controller.didChangeTabProperties(.title, for: self)
                }
            },
            view.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url else { return }
                    // The error page loads as about:blank; keep the address
                    // that failed, so reload retries it.
                    if url.scheme == "about", self.url != nil { return }
                    self.url = url
                    self.store?.sessionChanged()
                    Extensions.shared.controller.didChangeTabProperties(.URL, for: self)
                    // Single-page apps change address without a load, and
                    // their players turn up a while after the address does.
                    self.sampleTint(after: 0.5)
                    self.sampleTint(after: 3)
                }
            },
            view.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = view.isLoading
                    Extensions.shared.controller.didChangeTabProperties(.loading, for: self)
                }
            },
            view.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            view.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    // MARK: - Commands

    func load(_ destination: URL) {
        url = destination
        title = ""
        materialize().load(URLRequest(url: destination))
    }

    func reload() {
        guard let webView else { return }
        // After a failed load the view is showing the error page; go back to
        // the address itself rather than reloading that.
        if webView.url == nil || webView.url?.scheme == "about", let url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func zoom(by factor: Double?) {
        guard let webView else { return }
        webView.pageZoom = factor.map { min(3, max(0.5, webView.pageZoom * $0)) } ?? 1
    }

    /// WebKit's Web Inspector, docked in the window as in Safari. The call
    /// that opens it is not public, so a WebKit without it does nothing.
    func showInspector() {
        guard let webView, webView.responds(to: Selector(("_inspector"))),
              let inspector = webView.perform(Selector(("_inspector")))?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: Selector(("show"))) else { return }
        inspector.perform(Selector(("show")))
    }

    /// Leaving in-window full screen restores the web view's first-responder
    /// status, but not the focused DOM element — so a player like YouTube's,
    /// which binds its space/arrow keys to the player, stays deaf until the
    /// video is clicked. Focus the player in the page too, which a click would.
    func restorePageKeyboardFocus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        // Focus the player in the page too, which a click would: a player like
        // YouTube's binds its space/arrow keys to itself and stays deaf until
        // something inside it is focused.
        let js = "(function(){var v=document.querySelector('video');if(!v)return;var p=v.closest('[tabindex]')||v;try{p.focus({preventScroll:true});}catch(e){}})()"
        webView.evaluateJavaScript(js, in: nil, in: .page) { _ in }
    }

    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
    }

    func takeThumbnail() {
        guard !thumbnailInFlight, Date().timeIntervalSince(lastThumbnail) > 2,
              let webView, webView.window != nil, !webView.isHiddenOrHasHiddenAncestor, webView.bounds.width > 10 else { return }
        thumbnailInFlight = true
        let generation = navigationGeneration
        let configuration = WKSnapshotConfiguration()
        // The switcher draws these 220 points wide; twice that is enough for a
        // Retina screen.
        configuration.snapshotWidth = 440
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                MainActor.assumeIsolated { self?.thumbnailInFlight = false }
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.thumbnailInFlight = false
                    guard self.navigationGeneration == generation else { return }
                    self.thumbnailData = jpeg
                    self.lastThumbnail = Date()
                }
            }
        }
    }

    /// Reads the page's top colour. Asked more than once per load, because
    /// the first paint is often a placeholder the real page then replaces.
    func sampleTint(after delay: TimeInterval = 0) {
        tintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.store?.isVisible(self) == true else { return }
            self.sampleVideo()
            self.webView?.evaluateJavaScript(PageTint.script) { [weak self] result, _ in
                let numbers = (result as? [NSNumber])?.map(\.doubleValue) ?? []
                MainActor.assumeIsolated {
                    guard let self, let sampled = PageTint(components: numbers), sampled != self.tint else { return }
                    self.tint = sampled
                }
            }
        }
        tintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - The last click

    /// When a Command- or middle-click last happened in a page, so a
    /// `window.open` that follows in its wake is known to be that click's.
    private static var lastBackgroundClick: Date = .distantPast

    static func noteClick(command: Bool, button: Int) {
        if command || button > 0 { lastBackgroundClick = Date() }
    }

    static func clickAskedForBackground() -> Bool {
        Date().timeIntervalSince(lastBackgroundClick) < 1
    }

    // MARK: - Full screen inside the window

    /// Puts the page back to normal. Nothing happens until the page's script
    /// answers, which comes back through `pageFullscreenChanged`.
    func exitPageFullscreen() {
        guard isPageFullscreen, let webView else { return }
        webView.evaluateJavaScript(PageFullscreen.exitScript, in: nil, in: Self.ownWorld) { _ in }
    }

    fileprivate func pageFullscreenChanged(_ on: Bool) {
        guard isPageFullscreen != on else { return }
        isPageFullscreen = on
        store?.pageFullscreenChanged(self)
    }

    // MARK: - Picture in picture

    /// `completion` gets "entered", "left" or "none".
    func pictureInPicture(_ request: PictureInPicture.Request, completion: ((String) -> Void)? = nil) {
        guard let webView else { completion?("none"); return }
        webView.evaluateJavaScript(PictureInPicture.script(for: request)) { result, _ in
            completion?(result as? String ?? "none")
        }
    }

    private func sampleVideo() {
        webView?.evaluateJavaScript(PictureInPicture.hasVideoScript) { [weak self] result, _ in
            let found = result as? Bool ?? false
            MainActor.assumeIsolated {
                if let self, self.hasVideo != found { self.hasVideo = found }
            }
        }
    }

    /// Frees the web process. The row, address and thumbnail stay, and so does
    /// enough to put the page back as it was.
    func sleep() {
        guard let webView else { return }
        tintWork?.cancel()
        navigationGeneration += 1
        savedState = webView.interactionState
        finder.attach(nil)
        observations.removeAll()
        // Silence first. The view is torn down a moment after it is dropped,
        // and a video kept playing for that moment after its tab had closed.
        webView.pauseAllMediaPlayback()
        webView.closeAllMediaPresentations()
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
        if isPageFullscreen { pageFullscreenChanged(false) }
        isAsleep = true
        isLoading = false
        hasVideo = false
        frameActivity.removeAll()
        editedFrame = false
    }

    /// Whether anything would be lost by sleeping. Sound is asked of WebKit as
    /// well as the page, since a player inside a frame is invisible to the page.
    func activity(_ completion: @escaping (TabSleep.Activity) -> Void) {
        guard let webView else { return completion(TabSleep.Activity()) }
        let generation = navigationGeneration
        let capturing = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
        var audible = false
        if webView.responds(to: Selector(("_isPlayingAudio"))) {
            audible = (webView.value(forKey: "_isPlayingAudio") as? Bool) ?? false
        }
        var answered = false
        let timeout = DispatchWorkItem {
            guard !answered else { return }
            answered = true
            completion(TabSleep.Activity(unknown: true))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        webView.evaluateJavaScript(TabSleep.query, in: nil, in: Self.ownWorld) { [weak self, weak webView] result in
            guard !answered else { return }
            answered = true
            timeout.cancel()
            guard let self, let webView, self.webView === webView, self.navigationGeneration == generation,
                  let answer = (try? result.get()) as? [String: Any], answer["tracked"] as? Bool == true
            else { completion(TabSleep.Activity(unknown: true)); return }
            completion(TabSleep.Activity(
                playing: audible || self.frameActivity.values.contains(where: \.playing) || (answer["playing"] as? Bool ?? false),
                edited: self.editedFrame || (answer["edited"] as? Bool ?? false),
                capturing: capturing || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
            ))
        }
    }

    fileprivate func receiveActivity(_ body: [String: Any]) {
        guard let frame = body["frame"] as? String else { return }
        if body["gone"] as? Bool == true { frameActivity[frame] = nil; return }
        let edited = body["edited"] as? Bool ?? false
        editedFrame = editedFrame || edited
        frameActivity[frame] = TabSleep.Activity(playing: body["playing"] as? Bool ?? false, edited: edited)
    }

    private func loadFavicon() {
        guard let webView, let page = webView.url, let host = page.host, host != faviconHost else { return }
        faviconHost = host
        if let cached = FaviconCache.shared.cached(host: host) { favicon = cached }

        let script = """
        (function () {
          var link = document.querySelector('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
          return link ? link.href : null;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let declared = (result as? String).flatMap(URL.init(string:))
            let fallback = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico")
            Task { @MainActor in
                guard let self else { return }
                if let image = await FaviconCache.shared.fetch(host: host, candidates: [declared, fallback].compactMap { $0 }, keep: !self.isPrivate),
                   self.faviconHost == host {
                    self.favicon = image
                }
            }
        }
    }
}

private final class TabFullscreenBridge: NSObject, WKScriptMessageHandler {
    static let shared = TabFullscreenBridge()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let kind = message.body as? String else { return }
            (message.webView as? PageView)?.tab?.pageFullscreenChanged(kind == "enter")
        }
    }
}

private final class TabPiPBridge: NSObject, WKScriptMessageHandler {
    static let shared = TabPiPBridge()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let tab = (message.webView as? PageView)?.tab else { return }
            if (message.body as? [String: Any])?["entered"] as? Bool == true {
                PiPDrag.shared.restorePlace()
                return
            }
            // Only noted. The arrow is answered before this, when WebKit asks
            // for the page (see `webViewFullscreenMayReturnToInline`), and the
            // × wants nothing brought forward.
            let paused = (message.body as? [String: Any])?["paused"] as? Bool == true
            tab.log.add("pip", "video back inline, \(paused ? "paused (closed with ×)" : "still playing")")
        }
    }
}

private final class TabLogBridge: NSObject, WKScriptMessageHandler {
    static let shared = TabLogBridge()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
            let level = body["level"] as? String ?? "log"
            let frame = body["frame"] as? String ?? "top"
            (message.webView as? PageView)?.tab?.log.add(level, frame == "top" ? text : "[\(frame)] \(text)")
        }
    }
}

private final class TabActivityBridge: NSObject, WKScriptMessageHandler {
    static let shared = TabActivityBridge()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            (message.webView as? PageView)?.tab?.receiveActivity(body)
        }
    }
}

/// The web view, with what WKWebView cannot be configured to do: let
/// extensions add to the right-click menu, and paste text without its
/// formatting.
final class PageView: WKWebView {
    weak var tab: Tab?

    /// ⌘V pastes text as Paste and Match Style does: no fonts, colours or
    /// sizes from wherever it was copied. A page that reads the paste itself,
    /// as Google Docs does, is handed only the plain text. A copied file or
    /// image, or what a web app copied in its own formats (a slide in Google
    /// Slides), pastes as before, since plain text would lose it; see
    /// `PasteStyle`.
    ///
    /// WKWebView answers both selectors without declaring them, hence the
    /// names.
    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasImage = pasteboard.availableType(from: [.tiff, .png]) != nil
        let style = PasteStyle.choose(
            fromPage: pasteboard.availableType(from: [Self.pageWrittenType]) != nil,
            hasFile: pasteboard.availableType(from: [.fileURL]) != nil,
            hasImage: hasImage,
            hasText: pasteboard.availableType(from: [.string, .rtf, .rtfd, .html]) != nil,
            text: hasImage ? pasteboard.string(forType: .string) : nil
        )
        if style == .plain {
            perform(NSSelectorFromString("pasteAsPlainText:"), with: sender)
        } else {
            typealias Action = @convention(c) (AnyObject, Selector, Any?) -> Void
            let selector = #selector(paste(_:))
            guard let original = class_getMethodImplementation(WKWebView.self, selector) else { return }
            unsafeBitCast(original, to: Action.self)(self, selector, sender)
        }
    }

    /// The type WebKit adds when a page's script wrote the copy, through
    /// `clipboardData.setData` in its copy handler. It holds the types that
    /// only the page itself reads back.
    private static let pageWrittenType = NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data")

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let tab else { return }
        let items = Extensions.shared.menuItems(for: tab)
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    // WebKit tracks the pointer with an NSTrackingArea scoped to the key window
    // (`.activeInKeyWindow`) and no longer forwards mouseMoved to the view, so
    // that area is the only thing that drives the page's `:hover`. The effect:
    // a video's controls (YouTube's bar) never appear when you hover while Drift
    // is not the active window — intermittent, since it depends on which window
    // is key. Safari-like browsers broaden that area to stay active always; do
    // the same, every time WebKit rebuilds its tracking (on resize, re-parent,
    // navigation). Owner and userInfo are kept, so WebKit still gets the moves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // After WebKit has rebuilt its own areas for this layout pass.
        DispatchQueue.main.async { [weak self] in self?.widenHoverTracking() }
    }

    private func widenHoverTracking() {
        func widen(_ view: NSView) {
            for area in view.trackingAreas
            where area.options.contains(.mouseMoved) && area.options.contains(.activeInKeyWindow) {
                view.removeTrackingArea(area)
                view.addTrackingArea(NSTrackingArea(
                    rect: area.rect,
                    options: area.options.subtracting(.activeInKeyWindow).union(.activeAlways),
                    owner: area.owner,
                    userInfo: area.userInfo))
            }
            view.subviews.forEach(widen)
        }
        widen(self)
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log.add("nav", "start \(webView.url?.absoluteString ?? "?")")
        finder.navigationStarted()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let destination = action.request.url else { return decisionHandler(.allow, preferences) }

        if action.shouldPerformDownload {
            return decisionHandler(.download, preferences)
        }

        // mailto:, tel:, zoommtg: and the like belong to other apps. Sites
        // also try their own app's scheme to see if it is installed (FotMob's
        // fotmob://postrender); with no app for it, macOS would put up an
        // error, so such a link just goes nowhere.
        let scheme = destination.scheme?.lowercased() ?? ""
        let isExtensionPage = Extensions.shared.controller.extensionContext(for: destination) != nil
        if !isExtensionPage, !["http", "https", "about", "file", "blob", "data", "javascript"].contains(scheme) {
            if NSWorkspace.shared.urlForApplication(toOpen: destination) != nil {
                NSWorkspace.shared.open(destination)
            } else {
                log.add("nav", "no app opens \(scheme): links, ignored")
            }
            return decisionHandler(.cancel, preferences)
        }

        // Command-click and middle-click open behind, the way every browser
        // has it. WebKit numbers the buttons its own way; whatever the number,
        // a link navigation from any button but the first is a middle click,
        // since the right one brings a menu and never a navigation.
        if action.navigationType == .linkActivated {
            log.add("nav", "link click, button \(action.buttonNumber)\(action.modifierFlags.contains(.command) ? ", with Command" : "")")
        }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || action.buttonNumber > 1 {
            store?.newTab(destination, inBackground: !action.modifierFlags.contains(.shift), isPrivate: isPrivate)
            return decisionHandler(.cancel, preferences)
        }

        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            log.add("http", "\(http.statusCode) for \(http.url?.absoluteString ?? "?")")
        }
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !response.canShowMIMEType || disposition.hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        store?.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store?.downloads.track(download)
    }

    /// Download Image, Download Linked File and Download Video in the
    /// right-click menu. WebKit hands those downloads only to this private
    /// call, which Safari answers too. Unanswered, the download has no
    /// delegate to say where it goes, and WebKit drops it without a word.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webViewContextMenuDidCreateDownload(_ webView: WKWebView, _ download: WKDownload) {
        store?.downloads.track(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationGeneration += 1
        pageFullscreenChanged(false)
        frameActivity.removeAll()
        editedFrame = false
        lastThumbnail = .distantPast
        sampleTint(after: 0.25)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.add("nav", "finish \(webView.url?.absoluteString ?? "?")")
        finder.navigationFinished()
        if !isPrivate, let url = webView.url { store?.recordVisit(url: url, title: webView.title ?? "") }
        loadFavicon()
        sampleTint()
        sampleTint(after: 1.2)
        // Give the page a moment to paint before photographing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.store?.isVisible(self) == true else { return }
            self.takeThumbnail()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        log.add("crash", "web process ended for \(webView.url?.absoluteString ?? "?")")
        if store?.isVisible(self) == true { webView.reload() }
        else { sleep() }
    }

    private func showFailure(_ error: Error, in webView: WKWebView) {
        let failure = error as NSError
        log.add("load", "\(failure.domain) \(failure.code): \(failure.localizedDescription)")
        // Cancelled by another navigation, or handed off to a download: neither
        // is a failure worth a page.
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain", failure.code == 102 { return }

        let failed = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        if let failed { url = failed }
        title = "Can\u{2019}t open page"
        webView.loadHTMLString(
            ErrorPage.html(message: failure.localizedDescription, address: failed?.absoluteString ?? ""),
            baseURL: nil
        )
    }
}

// MARK: - Page dialogs and popups

extension Tab: WKUIDelegate {

    /// The picture-in-picture window's "back to the tab" arrow. WebKit will
    /// only put the video back once its page can be seen, and asks the
    /// browser, through this private call Safari answers too, to see to that.
    /// Unanswered, the arrow does nothing until the window is next in front.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        log.add("pip", "return arrow: WebKit asks for the page to be shown (active now: \(NSApp.isActive))")
        store?.returnedFromPictureInPicture(self)
    }

    /// The window's frame, which a page reads as `outerWidth` and
    /// `outerHeight`. Unanswered, WebKit reports both as 0, and Google Docs,
    /// taking the page for Safari, divides by them to guess the zoom and draws
    /// its text at a quarter of the screen's resolution.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewWindowFrame(_ webView: WKWebView, _ completion: @escaping (CGRect) -> Void) {
        completion(webView.window?.frame ?? store?.window?.frame ?? .zero)
    }

    /// A Web Inspector just opened, from the menu or Inspect Element. WebKit
    /// docks it inside the page's own container, which `WebPane.Host` clears
    /// and resizes on every tab switch, so it goes to a window of its own.
    @objc(_webView:didAttachLocalInspector:)
    func webViewDidAttachLocalInspector(_ webView: WKWebView, _ inspector: NSObject) {
        guard inspector.responds(to: Selector(("detach"))) else { return }
        inspector.perform(Selector(("detach")))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The gesture behind the site's window.open. WebKit does not pass the
        // click's modifiers on to this action, so the click itself is what is
        // consulted: a Command- or middle-click a moment ago asked for a tab
        // behind, and gets one.
        let behind = action.modifierFlags.contains(.command) || action.buttonNumber > 1 || Self.clickAskedForBackground()
        log.add("nav", "site opened a window (button \(action.buttonNumber)\(action.modifierFlags.contains(.command) ? ", with Command" : "")): \(behind ? "behind" : "in front")")
        return store?.openPopup(configuration: configuration, from: self, inBackground: behind)
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.close(self)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = pageAlert(message, from: frame)
        alert.addButton(withTitle: "OK")
        present(alert, on: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = pageAlert(message, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = pageAlert(prompt, from: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let what: String
        switch type {
        case .camera: what = "camera"
        case .microphone: what = "microphone"
        default: what = "camera and microphone"
        }
        if !isPrivate, SitePermissions.isAllowed(origin.host, what) { return decisionHandler(.grant) }

        let alert = NSAlert()
        alert.messageText = "Allow \(origin.host) to use your \(what)?"
        alert.informativeText = isPrivate ? "Asked each time in a private tab." : "Drift remembers a yes for this site."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        present(alert, on: webView) { response in
            let granted = response == .alertFirstButtonReturn
            if granted, !self.isPrivate { SitePermissions.allow(origin.host, what) }
            decisionHandler(granted ? .grant : .deny)
        }
    }

    private func pageAlert(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        // Always say who is talking, so a page cannot pass its words off as
        // the browser's.
        alert.messageText = "\(frame.securityOrigin.host.isEmpty ? "This page" : frame.securityOrigin.host) says"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, on webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

// MARK: - Small stores

/// Sites that have been told yes to the camera or microphone.
enum SitePermissions {
    private static let key = "drift.permissions.v1"

    static func isAllowed(_ host: String, _ what: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains("\(host)|\(what)")
    }

    static func allow(_ host: String, _ what: String) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        all.append("\(host)|\(what)")
        UserDefaults.standard.set(all, forKey: key)
    }
}

enum ErrorPage {
    static func html(message: String, address: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>
          body { font: 15px -apple-system, sans-serif; margin: 18vh auto 0; max-width: 460px; padding: 0 24px; color: #37352f; }
          h1 { font-size: 22px; margin: 0 0 8px; }
          p { color: #787774; line-height: 1.5; margin: 0 0 6px; word-break: break-word; }
          code { font: 12px ui-monospace, monospace; }
          @media (prefers-color-scheme: dark) { body { background: #191919; color: #ebebeb; } p { color: #9b9b9b; } }
        </style></head><body>
        <h1>Can\u{2019}t open this page</h1>
        <p>\(escaped(message))</p>
        <p><code>\(escaped(address))</code></p>
        <p>Press \u{2318}R to try again.</p>
        </body></html>
        """
    }
}

/// Site icons, by host. Kept on disk so restored tabs have their icon before
/// they have a web view.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1_048_576
        return cache
    }()
    private var fetching: [String: Task<NSImage?, Never>] = [:]

    func trim() { memory.removeAllObjects() }

    private static func smallImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    private let folder: URL = {
        let folder = Storage.directory.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Private fetches go through a session with no cache and no cookies of
    /// its own, so the request leaves no trace in the shared URL cache either.
    private static let ephemeral = URLSession(configuration: .ephemeral)
    private static func session(keep: Bool) -> URLSession { keep ? .shared : ephemeral }

    private func file(for host: String) -> URL {
        folder.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_"))
    }

    func cached(host: String) -> NSImage? {
        if let image = memory.object(forKey: host as NSString) { return image }
        guard let data = try? Data(contentsOf: file(for: host)), let image = Self.smallImage(data) else { return nil }
        memory.setObject(image, forKey: host as NSString, cost: 64 * 64 * 4)
        return image
    }

    /// `keep` false is a private tab: the icon is used and then forgotten,
    /// because a folder of icons named by host is a browsing history.
    func fetch(host: String, candidates: [URL], keep: Bool = true) async -> NSImage? {
        if keep {
            let modified = (try? file(for: host).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < 7 * 86_400, let cached = cached(host: host) { return cached }
            if let task = fetching[host] { return await task.value }
            let task = Task { await self.download(host: host, candidates: candidates, keep: true) }
            fetching[host] = task
            let result = await task.value
            fetching[host] = nil
            return result
        }
        return await download(host: host, candidates: candidates, keep: false)
    }

    private func download(host: String, candidates: [URL], keep: Bool) async -> NSImage? {
        for candidate in candidates {
            guard let (data, response) = try? await Self.session(keep: keep).data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let image = Self.smallImage(data)
            else { continue }
            if keep {
                memory.setObject(image, forKey: host as NSString, cost: 64 * 64 * 4)
                if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let small = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                    try? small.write(to: file(for: host), options: .atomic)
                }
            }
            return image
        }
        return cached(host: host)
    }
}
