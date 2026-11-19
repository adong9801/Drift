import Foundation

/// Google Docs in dark mode, which Google offers only in its phone apps. When
/// macOS is dark, a document and the editor round it are turned dark, and
/// the pictures in it keep their own colours.
///
/// Docs paints a page's text onto a canvas, so no style sheet can recolour
/// it; the whole page is inverted instead, with the hue turned back so blue
/// links stay blue. All the way: white paper becomes black and black text
/// white. (At 0.9 the paper was a dark grey, which was not dark enough.)
/// Pictures are the exception, turned back by inverting them again: a picture
/// in a document is an SVG <image> in the layer laid over the page's canvas,
/// and that whole layer holds nothing but pictures. WebKit ignores a CSS
/// filter on an SVG element itself, so it goes on that layer's <svg>, which
/// is an ordinary box. A full inversion undone is the picture as it was.
enum DocsDark {

    private static let enabledKey = "drift.darkDocs.v1"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let css = """
    @media (prefers-color-scheme: dark) {
      html { filter: invert(1) hue-rotate(180deg) !important; }
      img, video, canvas.kix-canvas-tile-content ~ .kix-canvas-tile-content > svg {
        filter: invert(1) hue-rotate(180deg) !important;
      }
    }
    """

    /// Runs at the start of every page, in Drift's own world, and leaves at
    /// once anywhere but a document: Sheets, Slides and Forms share the host,
    /// and a slide's own colours are the point of it. The sheet is kept, so
    /// the menu switch can turn it off and on in pages already open.
    static var script: String {
        let quoted = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        return """
        (function () {
          if (location.hostname !== 'docs.google.com' || location.pathname.indexOf('/document/') !== 0) return;
          var sheet = new CSSStyleSheet();
          sheet.replaceSync(`\(quoted)`);
          sheet.disabled = \(enabled ? "false" : "true");
          document.adoptedStyleSheets = Array.prototype.concat.call(document.adoptedStyleSheets || [], [sheet]);
          globalThis.__driftDocsDark = sheet;
        })();
        """
    }

    /// For a page already open: on or off. Does nothing on any other page.
    static func switchScript(on: Bool) -> String {
        "if (globalThis.__driftDocsDark) globalThis.__driftDocsDark.disabled = \(on ? "false" : "true");"
    }
}
