import AppKit
import ObjectiveC

/// Takes the animation out of picture in picture: the window is simply there,
/// and on the way back the video is simply inline again.
///
/// The system flies the window out of the page and, on return, back into it,
/// and the flight stutters and flickers. There is no setting for it. The
/// window is drawn by the system's PIPAgent, told what to do by an object in
/// this process, `PIPAgentProxy`; that object is made here to ask for the
/// window to be shown without animating, and to restore it where it is rather
/// than into the page. Both calls are private, so each is changed only if it is
/// there with exactly the arguments expected; otherwise the animation stays.
enum PiPInstant {

    /// Harmless to call again.
    static func install() { _ = installed }

    private static let installed: Void = {
        // WebKit loads the framework only when a video first goes into
        // picture in picture, and its classes do not exist until then.
        _ = dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_NOW)
        guard let proxy = NSClassFromString("PIPAgentProxy") else { return }
        showWithoutAnimating(proxy)
        restoreInPlace(proxy)
    }()

    private static func showWithoutAnimating(_ proxy: AnyClass) {
        let selector = NSSelectorFromString("agentShowPIP:fromScreenRect:animating:withFence:completion:")
        guard let method = class_getInstanceMethod(proxy, selector),
              shape(of: method) == "v@:I{CGRect={CGPoint=dd}{CGSize=dd}}B@@?" else { return }
        typealias Show = @convention(c) (AnyObject, Selector, UInt32, CGRect, Bool, AnyObject?, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Show.self)
        let replacement: @convention(block) (AnyObject, UInt32, CGRect, Bool, AnyObject?, AnyObject?) -> Void = { agent, id, from, _, fence, completion in
            original(agent, selector, id, from, false, fence, completion)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Restoring flies the window into the page, where it is gone at once on
    /// landing. Asked to land where it already is, it has nowhere to fly.
    /// Should the window not be found, it is closed instead, which shrinks it
    /// away where it is: slower, but no flight either. WebKit puts the video
    /// back in the page itself, so neither leaves anything undone.
    private static func restoreInPlace(_ proxy: AnyClass) {
        let restoreSelector = NSSelectorFromString("agentRestorePIP:toScreenRect:completion:")
        let closeSelector = NSSelectorFromString("agentClosePIP:completion:")
        guard let restore = class_getInstanceMethod(proxy, restoreSelector),
              shape(of: restore) == "v@:I{CGRect={CGPoint=dd}{CGSize=dd}}@?",
              let close = class_getInstanceMethod(proxy, closeSelector),
              shape(of: close) == "v@:I@?" else { return }
        typealias Restore = @convention(c) (AnyObject, Selector, UInt32, CGRect, AnyObject?) -> Void
        typealias Close = @convention(c) (AnyObject, Selector, UInt32, AnyObject?) -> Void
        let restoreOriginal = unsafeBitCast(method_getImplementation(restore), to: Restore.self)
        let closeOriginal = unsafeBitCast(method_getImplementation(close), to: Close.self)
        let replacement: @convention(block) (AnyObject, UInt32, CGRect, AnyObject?) -> Void = { agent, id, _, completion in
            if let here = windowFrame() {
                restoreOriginal(agent, restoreSelector, id, here, completion)
            } else {
                closeOriginal(agent, closeSelector, id, completion)
            }
        }
        method_setImplementation(restore, imp_implementationWithBlock(replacement))
    }

    /// Where the picture-in-picture window is now, in screen coordinates as
    /// AppKit counts them, from the bottom left of the main display. Nil
    /// unless the agent has exactly one window up.
    private static func windowFrame() -> CGRect? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.PIPAgent").first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let height = NSScreen.screens.first?.frame.height else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == agent.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        guard frames.count == 1, let frame = frames.first, frame.width > 0, frame.height > 0 else { return nil }
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The method's argument types, without the stack offsets, which are no
    /// business of ours.
    private static func shape(of method: Method) -> String? {
        guard let encoding = method_getTypeEncoding(method) else { return nil }
        return String(cString: encoding).filter { !$0.isNumber }
    }
}
