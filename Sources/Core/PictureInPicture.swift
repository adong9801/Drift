import Foundation

/// The script that moves a page's video in and out of picture in picture.
///
/// It goes through WebKit's own presentation-mode API rather than the page's
/// player, because sites like YouTube hide the native control and offer none
/// of their own.
enum PictureInPicture {

    static let userDefaultsKey = "drift.autoPiP.v1"

    /// Whether leaving a tab, or the app, with a video playing pops the video
    /// out. On unless switched off.
    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    enum Request {
        /// The user asked: in if out, out if in.
        case toggle
        /// The page went out of sight: another tab was chosen, or another app.
        /// Only a video that is playing, with sound, is worth following the
        /// user around; a muted autoplaying clip is not.
        case tabHidden
        /// The page is back in front. Only undoes what `tabHidden` did, so a
        /// video the user popped out on purpose stays out.
        case tabShown
    }

    /// Answers "entered", "left", or "none".
    static func script(for request: Request) -> String {
        let mode: String
        switch request {
        case .toggle: mode = "toggle"
        case .tabHidden: mode = "hidden"
        case .tabShown: mode = "shown"
        }
        return """
        (function (mode) {
          var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
          var out = videos.filter(function (v) { return v.webkitPresentationMode === 'picture-in-picture'; })[0];
          if (mode === 'shown' || (mode === 'toggle' && out)) {
            if (out && (mode === 'toggle' || window.__driftAutoPiP)) {
              window.__driftPiPByUs = true;
              out.webkitSetPresentationMode('inline');
              window.__driftAutoPiP = false;
              return 'left';
            }
            return 'none';
          }
          if (out) return 'none';
          var playing = videos.filter(function (v) {
            return !v.paused && !v.ended && v.readyState > 2 && v.videoWidth > 0;
          });
          var pool = mode === 'hidden'
            ? playing.filter(function (v) { return !v.muted && v.volume > 0; })
            : (playing.length ? playing : videos.filter(function (v) { return v.videoWidth > 0; }));
          pool.sort(function (a, b) { return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; });
          var video = pool[0];
          if (!video || !video.webkitSupportsPresentationMode || !video.webkitSupportsPresentationMode('picture-in-picture')) return 'none';
          video.webkitSetPresentationMode('picture-in-picture');
          window.__driftAutoPiP = mode === 'hidden';
          return 'entered';
        })('\(mode)')
        """
    }

    /// In Drift's world from document start: notes each change of the video's
    /// presentation for the debugging archive, when it went into picture in
    /// picture, and which way it left. The window's × pauses the video before
    /// putting it back; its arrow leaves it playing.
    static let returnWatcher = """
    ['play', 'pause'].forEach(function (name) {
      document.addEventListener(name, function (event) {
        var v = event.target;
        if (!v || (v.tagName !== 'VIDEO' && v.tagName !== 'AUDIO')) return;
        var r = v.getBoundingClientRect ? v.getBoundingClientRect() : { width: 0, height: 0 };
        var style = window.getComputedStyle(v);
        var shown = r.width > 0 && r.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
        var all = document.querySelectorAll('video, audio').length;
        try { webkit.messageHandlers.driftLog.postMessage({ level: 'media', text: name + ' on ' + v.tagName.toLowerCase() + '#' + (v.id || '-') + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + (shown ? ' shown' : ' HIDDEN') + ', muted ' + v.muted + ', volume ' + v.volume + ', of ' + all + ' media elements' }); } catch (e) {}
      }, true);
    });

    document.addEventListener('webkitpresentationmodechanged', function (event) {
      var video = event.target;
      if (!video || video.tagName !== 'VIDEO') return;
      var mode = video.webkitPresentationMode;
      if (mode === 'picture-in-picture') {
        try { webkit.messageHandlers.driftPiP.postMessage({ entered: true }); } catch (e) {}
      }
      try { webkit.messageHandlers.driftLog.postMessage({ level: 'pip', text: 'presentation mode ' + mode + ', was ' + window.__driftPiPWas + ', paused ' + video.paused + ', by Drift ' + !!window.__driftPiPByUs + ', document ' + document.visibilityState }); } catch (e) {}
      if (mode === 'inline' && window.__driftPiPWas === 'picture-in-picture' && !window.__driftPiPByUs) {
        try { webkit.messageHandlers.driftPiP.postMessage({ paused: video.paused }); } catch (e) {}
      }
      window.__driftPiPByUs = false;
      window.__driftPiPWas = mode;
    }, true);
    """

    static let hasVideoScript = """
    (function () {
      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) { if (videos[i].videoWidth > 0 || videos[i].currentSrc) return true; }
      return false;
    })()
    """
}
