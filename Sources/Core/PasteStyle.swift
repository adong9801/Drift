import Foundation

/// What ⌘V in a page does with the clipboard. Text pastes as Paste and Match
/// Style does, without the fonts, colours and sizes of wherever it came from.
/// Anything plain text would lose pastes as it is: a copied file, an image, or
/// a web app's own copy.
enum PasteStyle: Equatable {
    case plain
    case asIs

    /// `fromPage`: a page's script wrote the copy, which WebKit marks with a
    /// clipboard type of its own. `text` is the clipboard's plain text, if any.
    static func choose(fromPage: Bool, hasFile: Bool, hasImage: Bool, hasText: Bool, text: String?) -> PasteStyle {
        // A slide or a shape in Google Slides, cells in Sheets, blocks in
        // Notion: the app copies them in formats only it reads back, with
        // their text beside them. Pasted plain, the page is handed the text
        // alone and the slide is lost. Formatted text a site copied this way
        // keeps its formatting too, which is the price of not breaking them.
        if fromPage || hasFile || !hasText { return .asIs }
        if hasImage, isJustAnAddress(text) { return .asIs }
        return .plain
    }

    /// Copy Image puts the image's address on the clipboard as text beside the
    /// picture, and when the image is a link, as every Google Images result
    /// is, the link's address instead. Pasted as plain text, the image would
    /// arrive as that address. Chrome's Copy Image puts no text at all.
    /// Anything more than one address is real text copied with a picture of
    /// itself, as Excel and Word do, and still pastes plain.
    static func isJustAnAddress(_ text: String?) -> Bool {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard !trimmed.contains(where: \.isWhitespace), let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "data", "blob", "file"].contains(scheme)
    }
}
