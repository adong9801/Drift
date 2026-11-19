import Foundation

/// Keeping the text being read still while a page changes above it: scroll
/// anchoring, which Chrome and Firefox have long had on, and which WebKit has
/// but ships turned off.
///
/// Long chats are where it shows. ChatGPT keeps only the messages near the
/// screen in the page and puts the others back as the reader scrolls up to
/// them. With anchoring, each one put back above the screen moves the scroll
/// position by its own height, and the text in view stays where it is.
/// Without it, the text was shoved down by every message, and the page
/// jumped as it scrolled. (Measured on such a page: 300px of movement for a
/// 300px message, against none.) See also ChatGPT's entry in `SiteQuirks`.
enum SteadyScrolling {

    static let feature = "CSSScrollAnchoringEnabled"

    static let userDefaultsKey = "drift.steadyScrolling.v1"

    /// On unless switched off in Settings.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }
}
