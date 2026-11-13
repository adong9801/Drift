import AppKit

@MainActor
final class DefaultBrowser: ObservableObject {
    static let shared = DefaultBrowser()

    @Published private(set) var isDefault = false
    @Published private(set) var requesting = false
    @Published private(set) var error: String?

    func refresh() {
        isDefault = ["http", "https"].allSatisfy(isHandler)
        if isDefault { error = nil }
    }

    private func isHandler(for scheme: String) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              let url = URL(string: "\(scheme)://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        else { return false }
        return Bundle(url: handler)?.bundleIdentifier == identifier
    }

    /// Only called by an explicit user action. macOS presents its own consent
    /// dialog. Check each scheme in sequence so dialogs never overlap.
    func request() async {
        guard !requesting else { return }
        requesting = true
        error = nil
        defer { requesting = false; refresh() }
        do {
            for scheme in ["http", "https"] where !isHandler(for: scheme) {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme
                )
            }
        } catch {
            self.error = "Default-browser setup did not finish: \(error.localizedDescription)"
        }
    }

    static func claim() {
        Task {
            await shared.request()
            if let message = shared.error {
                let alert = NSAlert()
                alert.messageText = "Default browser"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
