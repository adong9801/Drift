import Foundation

/// The colour along the top of a page, which the window's chrome takes on when
/// the sidebar is hidden so the bar and the page read as one surface.
struct PageTint: Equatable {
    /// sRGB, 0–1.
    let red: Double
    let green: Double
    let blue: Double

    /// From the `[r, g, b]` in 0–255 that the sampling script returns.
    init?(components: [Double]) {
        guard components.count >= 3, components.prefix(3).allSatisfy({ $0.isFinite }) else { return nil }
        red = min(1, max(0, components[0] / 255))
        green = min(1, max(0, components[1] / 255))
        blue = min(1, max(0, components[2] / 255))
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Whether white text reads better on it than black. The crossover is where
    /// the two contrast ratios are equal.
    var wantsLightText: Bool { luminance < 0.179 }

    /// Finds the colour. A declared theme colour wins, as it does in Safari;
    /// failing that, whatever opaque background is actually under the top edge.
    static let script = """
    (function () {
      // What the eye sees, which is not what the page asked for when the
      // whole page is under a filter, as Google Docs is in dark mode (see
      // DocsDark): the same invert and half turn of hue, done by hand.
      function seen(rgb) {
        var filter = getComputedStyle(document.documentElement).filter || '';
        var invert = filter.match(/invert\\(([\\d.]+)(%?)\\)/);
        if (!invert) return rgb;
        var a = parseFloat(invert[1]) / (invert[2] ? 100 : 1);
        var c = rgb.map(function (v) { return 255 * a + (1 - 2 * a) * v; });
        if (/hue-rotate\\(180deg\\)/.test(filter)) {
          c = [-0.574 * c[0] + 1.43 * c[1] + 0.144 * c[2],
               0.426 * c[0] + 0.43 * c[1] + 0.144 * c[2],
               0.426 * c[0] + 1.43 * c[1] - 0.856 * c[2]];
        }
        return c.map(function (v) { return Math.max(0, Math.min(255, Math.round(v))); });
      }
      return seen((function () {
      function normalised(css) {
        var probe = document.createElement('div');
        probe.style.color = css;
        probe.style.display = 'none';
        document.documentElement.appendChild(probe);
        var value = getComputedStyle(probe).color;
        probe.remove();
        return value;
      }
      function opaque(css) {
        var match = css && css.match(/rgba?\\(([^)]+)\\)/);
        if (!match) return null;
        var parts = match[1].split(/[ ,\\/]+/).map(parseFloat);
        if (parts.length > 3 && parts[3] < 0.9) return null;
        return [parts[0], parts[1], parts[2]];
      }
      var metas = document.querySelectorAll('meta[name="theme-color"]');
      for (var i = 0; i < metas.length; i++) {
        var media = metas[i].getAttribute('media');
        if (media && !matchMedia(media).matches) continue;
        var declared = opaque(normalised(metas[i].content));
        if (declared) return declared;
      }
      var stack = document.elementsFromPoint(innerWidth / 2, 2);
      for (var j = 0; j < stack.length; j++) {
        var found = opaque(getComputedStyle(stack[j]).backgroundColor);
        if (found) return found;
      }
      // A body background paints the whole canvas even where the body itself
      // does not reach, which is exactly the strip being asked about.
      var canvas = [document.body, document.documentElement];
      for (var k = 0; k < canvas.length; k++) {
        var painted = canvas[k] && opaque(getComputedStyle(canvas[k]).backgroundColor);
        if (painted) return painted;
      }
      var scheme = getComputedStyle(document.documentElement).colorScheme || '';
      var dark = scheme.indexOf('dark') >= 0 && matchMedia('(prefers-color-scheme: dark)').matches;
      return dark ? [30, 30, 30] : [255, 255, 255];
      })());
    })()
    """
}
