import Foundation

/// Taking the edge off a white page arriving in a dark room: bright pages are
/// veiled a little when the system is in dark mode, so the eye is not asked to
/// jump between extremes.
enum EyeComfort {

    private static let dimKey = "drift.dimBrightPages.v1"

    /// Whether bright pages are veiled in dark mode. Off unless turned on: on
    /// a page of black text, such as Docs, the veil reads as washed out.
    static var dimsBrightPages: Bool {
        get { UserDefaults.standard.object(forKey: dimKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: dimKey) }
    }

    /// The veil's strength for a page of the given luminance, 0 to 1. Nothing
    /// for a dark page or in light surroundings; up to `strongest` for a white
    /// one, ramping in between so a mid-grey page is barely touched.
    static let strongest = 0.16

    static func dimming(luminance: Double?, darkSurroundings: Bool, enabled: Bool = dimsBrightPages) -> Double {
        guard enabled, darkSurroundings, let luminance else { return 0 }
        let low = 0.25, high = 0.6
        guard luminance > low else { return 0 }
        let fraction = min(1, (luminance - low) / (high - low))
        return (fraction * strongest * 1000).rounded() / 1000
    }
}
