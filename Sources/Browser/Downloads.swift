import AppKit
import WebKit

/// One download, as the sidebar shows it.
@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var filename: String
    @Published var fraction = 0.0
    @Published var state: State = .running
    var destination: URL?
    fileprivate var progressObservation: NSKeyValueObservation?
    fileprivate weak var download: WKDownload?

    enum State: Equatable {
        case running
        case finished
        case failed(String)
    }

    init(filename: String) { self.filename = filename }
}

/// Saves downloads into ~/Downloads, never over an existing file.
@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {

    @Published private(set) var items: [DownloadItem] = []
    private var byDownload: [ObjectIdentifier: DownloadItem] = [:]

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.download = download
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in item?.fraction = fraction }
        }
        byDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .failed("Cancelled")
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    func reveal(_ item: DownloadItem) {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    // MARK: WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.freeName(for: suggestedFilename, in: folder)
        if let item = byDownload[ObjectIdentifier(download)] {
            item.filename = destination.lastPathComponent
            item.destination = destination
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.fraction = 1
        item.state = .finished
        // The bounce in the Dock's Downloads stack.
        if let path = item.destination?.path {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"),
                object: path
            )
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if item.state == .running { item.state = .failed(error.localizedDescription) }
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf"...
    static func freeName(for suggested: String, in folder: URL) -> URL {
        let clean = suggested.replacingOccurrences(of: "/", with: "_")
        let name = clean.isEmpty ? "Download" : clean
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}
