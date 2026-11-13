import WebKit

/// Find state belongs to the page, so switching tabs never applies a late
/// answer to another page. Use WebKit's rendered-text search, including frames.
@MainActor
final class PageFind: ObservableObject {
    enum Result: Equatable { case idle, searching, found, missing, unavailable }

    @Published var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    @Published var caseSensitive = false {
        didSet { if caseSensitive != oldValue { schedule() } }
    }
    @Published private(set) var result: Result = .idle
    @Published var focusRequest = 0
    private weak var webView: WKWebView?
    private var pending: DispatchWorkItem?
    private var revision = 0
    private var presented = false

    func attach(_ view: WKWebView?) {
        pending?.cancel()
        revision += 1
        webView = view
        result = .idle
    }

    func present() {
        presented = true
        schedule()
    }

    func dismiss() {
        presented = false
        clearHighlights()
    }

    func navigationStarted() {
        pending?.cancel()
        revision += 1
        result = .idle
    }

    func navigationFinished() {
        if presented { schedule() }
    }

    func next(backwards: Bool = false) {
        pending?.cancel()
        guard !query.isEmpty else { focusRequest += 1; return }
        search(backwards: backwards)
    }

    private func schedule() {
        pending?.cancel()
        revision += 1
        guard !query.isEmpty else { clearHighlights(); return }
        guard presented else { result = .idle; return }
        result = .searching
        let work = DispatchWorkItem { [weak self] in self?.search(backwards: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func search(backwards: Bool) {
        guard let webView else { result = .unavailable; return }
        revision += 1
        let request = revision
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = caseSensitive
        result = .searching
        webView.find(query, configuration: configuration) { [weak self, weak webView] answer in
            guard let self, let webView, self.webView === webView, self.revision == request else { return }
            self.result = answer.matchFound ? .found : .missing
        }
    }

    private func clearHighlights() {
        pending?.cancel()
        revision += 1
        result = .idle
        // WebKit removes its find indicator for an empty search. The ordinary
        // text selection remains, so the user can still copy the last match.
        webView?.find("", configuration: WKFindConfiguration()) { _ in }
    }
}
