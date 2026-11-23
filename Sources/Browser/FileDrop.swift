import AppKit

/// A drop of files another app has already written, handed to the page as
/// those files rather than as the other app's promise to write them.
///
/// A screenshot dragged from its thumbnail is on disk before the drag
/// starts, and the drag carries both the file and a promise of it. WebKit
/// takes the promise whenever there is one: it asks the other app to write
/// the file again into a folder of WebKit's, and waits to read it there.
/// macOS keeps the drag going until that hand-over is done, and once it
/// never finished: the screenshot app waited for a read that never came,
/// the drop never ended, and the whole screen stayed caught in it, one
/// window taking every click, until Drift was quit. The files themselves
/// need no hand-over.
///
/// The page gets copies, as from a promise: the screenshot app clears its
/// own away once the drag is over, which can be before the page has read
/// them. Copies on the same disk are clones, so they cost nothing.
final class FileDrop: NSObject, NSDraggingInfo {

    /// The files, if this is such a drop: from another app, carrying a
    /// promise, and with every file it names already on disk. Nil for
    /// anything else, which WebKit handles as it always has: a promise with
    /// no files yet (Photos, Mail), plain files (Finder), or a drag from a
    /// page in Drift.
    static func alreadyWritten(_ info: NSDraggingInfo) -> FileDrop? {
        guard info.draggingSource == nil else { return nil }
        let pasteboard = info.draggingPasteboard
        guard pasteboard.types?.contains(promiseType) == true else { return nil }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { return nil }
        guard let copies = copy(urls) else { return nil }
        return FileDrop(info, files: copies)
    }

    /// WebKit's name for the promise, NSFilesPromisePboardType.
    static let promiseType = NSPasteboard.PasteboardType("Apple files promise pasteboard type")
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    let files: [URL]
    let draggingPasteboard: NSPasteboard
    private let original: NSDraggingInfo

    private init(_ original: NSDraggingInfo, files: [URL]) {
        self.original = original
        self.files = files
        // One pasteboard of Drift's own, reused: the page reads the drop's
        // types from it by name, and only the files are on it.
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("local.prototype.drift.drop"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(files.map { $0 as NSURL })
        draggingPasteboard.setPropertyList(files.map(\.path), forType: Self.filenamesType)
    }

    /// Into a folder of its own in Drift's temporary folder, keeping names.
    private static func copy(_ urls: [URL]) -> [URL]? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dropped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try urls.map { url in
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                return copy
            }
        } catch {
            return nil
        }
    }

    // Everything else is the drag's own.
    var draggingDestinationWindow: NSWindow? { original.draggingDestinationWindow }
    var draggingSourceOperationMask: NSDragOperation { original.draggingSourceOperationMask }
    var draggingLocation: NSPoint { original.draggingLocation }
    var draggedImageLocation: NSPoint { original.draggedImageLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { original.draggingSource }
    var draggingSequenceNumber: Int { original.draggingSequenceNumber }
    func slideDraggedImage(to screenPoint: NSPoint) { original.slideDraggedImage(to: screenPoint) }
    var draggingFormation: NSDraggingFormation {
        get { original.draggingFormation }
        set { original.draggingFormation = newValue }
    }
    var animatesToDestination: Bool {
        get { original.animatesToDestination }
        set { original.animatesToDestination = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { original.numberOfValidItemsForDrop }
        set { original.numberOfValidItemsForDrop = newValue }
    }
    /// The items on Drift's pasteboard, which are the files. Not passed on
    /// to the drag's own: AppKit may keep the block, and this one may not be.
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop: ObjCBool = false
        for (index, object) in objects.enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { original.springLoadingHighlight }
    func resetSpringLoading() { original.resetSpringLoading() }
}
