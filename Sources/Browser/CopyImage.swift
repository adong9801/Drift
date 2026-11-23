import AppKit

/// Copy Image leaves the picture alone on the clipboard, as Chrome's does.
///
/// WebKit's Copy Image puts the image's address beside it: as plain text, as
/// a link, in a web archive and in rich text. A page's paste handler is given
/// all of them, and a message box that reads the text, as Instagram's does,
/// takes the address and not the picture. Copy Image Address is in the same
/// menu for anyone who wants the address.
@MainActor
final class CopyImage: NSObject {

    static let identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyImage")

    /// WebKit's own target and action for the item, which do the copying.
    private let target: AnyObject?
    private let action: Selector

    /// The one for the menu open now. A menu item does not keep its target.
    private static var current: CopyImage?
    /// The clipboard; a test sets its own.
    static var pasteboard: () -> NSPasteboard = { .general }

    private init(target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
    }

    /// Takes over the menu's Copy Image item, if it has one.
    static func adopt(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.identifier == identifier }), let action = item.action else { return }
        let wrapper = CopyImage(target: item.target, action: action)
        current = wrapper
        item.target = wrapper
        item.action = #selector(copyImage(_:))
    }

    @objc private func copyImage(_ sender: NSMenuItem) {
        let pasteboard = Self.pasteboard()
        let before = pasteboard.changeCount
        // WebKit finds what was clicked from the item it is handed.
        NSApp.sendAction(action, to: target, from: sender)
        Self.trimOnceWritten(pasteboard, since: before)
    }

    /// What WebKit writes after naming its types, each in a step of its own.
    private static let writtenLater: [NSPasteboard.PasteboardType] = [.tiff, .rtfd, NSPasteboard.PasteboardType("com.apple.webarchive")]

    /// Whether WebKit has written the parts it named. It names them all
    /// first, so a part can be listed before it is there; one written after
    /// the cut would come back.
    private static func isWritten(_ pasteboard: NSPasteboard) -> Bool {
        let named = Set(pasteboard.types ?? [])
        return writtenLater.allSatisfy { !named.contains($0) || pasteboard.data(forType: $0) != nil }
    }

    /// The page's process does the writing, a moment after the click and in
    /// several steps. Once the clipboard has changed and every part WebKit
    /// named is in (or half a second has passed), the copy is cut down to
    /// the picture.
    static func trimOnceWritten(_ pasteboard: NSPasteboard, since count: Int, giveUp: Date = Date() + 3, done: (() -> Void)? = nil) {
        watch(pasteboard.name, since: count, changed: nil, giveUp: giveUp, done: done)
    }

    private static func watch(_ name: NSPasteboard.Name, since count: Int, changed: (at: Date, to: Int)?, giveUp: Date, done: (() -> Void)?) {
        let pasteboard = NSPasteboard(name: name)
        let now = Date()
        var changed = changed
        if changed == nil, pasteboard.changeCount != count { changed = (now, pasteboard.changeCount) }
        if let changed {
            // Something else copied meanwhile is left as it is.
            guard pasteboard.changeCount == changed.to else { done?(); return }
            if isWritten(pasteboard) || now.timeIntervalSince(changed.at) > 0.5 {
                return trim(pasteboard, done: done)
            }
        } else if now > giveUp {
            done?()
            return
        }
        let next = changed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            MainActor.assumeIsolated { watch(name, since: count, changed: next, giveUp: giveUp, done: done) }
        }
    }

    /// Whether the clipboard holds what WebKit's Copy Image writes: a picture
    /// with a link beside it.
    static func isImageWithAddress(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.tiff]) != nil && pasteboard.availableType(from: [.URL]) != nil
    }

    /// Replaces WebKit's copy with the picture alone: PNG, which pages and
    /// most apps take, and the TIFF WebKit wrote, which every Mac app reads.
    /// The PNG is made off the main thread, since a large photo takes a while.
    static func trim(_ pasteboard: NSPasteboard, done: (() -> Void)? = nil) {
        guard isImageWithAddress(pasteboard), let tiff = pasteboard.data(forType: .tiff) else { done?(); return }
        let count = pasteboard.changeCount
        let name = pasteboard.name
        DispatchQueue.global(qos: .userInitiated).async {
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard(name: name)
                if pasteboard.changeCount == count {
                    pasteboard.clearContents()
                    let item = NSPasteboardItem()
                    if let png { item.setData(png, forType: .png) }
                    item.setData(tiff, forType: .tiff)
                    pasteboard.writeObjects([item])
                }
                done?()
            }
        }
    }
}
