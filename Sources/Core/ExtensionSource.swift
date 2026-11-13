import Foundation

/// Working out where an extension's files are: on the web, and inside whatever
/// was downloaded.
enum ExtensionSource {

    /// Chrome's update service, which serves the packed extension for an id.
    private static let storeTemplate =
        "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=138.0&acceptformat=crx2,crx3&x=id%3D{id}%26uc"

    /// A Chrome Web Store page, a bare store id, or a direct link to an archive.
    static func downloadURL(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = storeID(in: text) {
            return URL(string: storeTemplate.replacingOccurrences(of: "{id}", with: id))
        }
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        let path = url.path.lowercased()
        return [".zip", ".crx", ".xpi"].contains(where: path.hasSuffix) ? url : nil
    }

    /// Store ids are 32 letters, a to p: a hash written in base 16 with the
    /// digits shifted into the alphabet.
    static func storeID(in text: String) -> String? {
        func isID(_ candidate: Substring) -> Bool {
            candidate.count == 32 && candidate.allSatisfy { ("a"..."p").contains($0) }
        }
        if isID(Substring(text)) { return text }
        guard let url = URL(string: text), let host = url.host,
              host == "chromewebstore.google.com" || host == "chrome.google.com"
        else { return nil }
        return url.path.split(separator: "/").last(where: isID).map(String.init)
    }

    /// The folder holding manifest.json: the top, or one level down, which is
    /// how archives made by zipping a folder come out.
    static func manifestRoot(in folder: URL) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children.first { manager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }
}
