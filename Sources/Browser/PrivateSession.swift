import AppKit

/// The private window's store, for as long as that window is open. Opening the
/// window makes one; closing it ends the session, and with it the private
/// cookies, storage and tabs. The next private window starts from nothing.
@MainActor
final class PrivateSession: ObservableObject {

    static let shared = PrivateSession()

    @Published private(set) var store: BrowserStore?

    /// The store for the private window, made if there is not one already.
    @discardableResult
    func begin() -> BrowserStore {
        if let store { return store }
        let fresh = BrowserStore(isPrivateWindow: true)
        store = fresh
        Extensions.shared.privateWindowOpened(fresh)
        return fresh
    }

    func end() {
        Extensions.shared.privateWindowClosed()
        store?.endSession()
        store = nil
        WindowRouter.shared.active = .shared
    }
}

/// Which window the menu bar is talking to: whichever is in front.
@MainActor
final class WindowRouter: ObservableObject {
    static let shared = WindowRouter()
    @Published var active: BrowserStore = .shared
}
