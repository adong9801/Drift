import AppKit
import WebKit

/// The Chrome Web Store's "Add to Drift" button, Drift's side of it; see
/// `WebStore`. Answers only the store's own top frame, and installs nothing
/// without the usual question first.
@MainActor
final class WebStoreBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = WebStoreBridge()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == WebStore.host,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let id = body["id"] as? String, ExtensionSource.storeID(in: id) == id
        else { return replyHandler(nil, "not the store") }
        let name = body["name"] as? String
        let extensions = Extensions.shared
        func state() -> String { extensions.installed(storeID: id, name: name) == nil ? "not installed" : "installed" }

        switch kind {
        case "state":
            replyHandler(state(), nil)
        case "install":
            Task { @MainActor in
                // The page's own address, which names the extension, is what
                // is kept as its source for updates.
                let page = (body["page"] as? String).flatMap { ExtensionSource.storeID(in: $0) == id ? $0 : nil }
                await extensions.install(fromWeb: page ?? id)
                if let error = extensions.lastError {
                    let alert = NSAlert()
                    alert.messageText = "\(name ?? "The extension") could not be added"
                    alert.informativeText = error
                    alert.runModal()
                }
                replyHandler(state(), nil)
            }
        case "remove":
            guard let record = extensions.installed(storeID: id, name: name) else { return replyHandler(state(), nil) }
            let alert = NSAlert()
            alert.messageText = "Remove \(extensions.name(of: record)) from Drift?"
            alert.informativeText = "You can add it again from here later, but anything it has saved may be gone."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { extensions.remove(record) }
            replyHandler(state(), nil)
        default:
            replyHandler(nil, "unknown request")
        }
    }
}
