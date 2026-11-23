import Foundation

/// Keeps YouTube's video in MP4 by saying WebM video cannot be played.
///
/// For some accounts YouTube's player makes its video buffer for MP4 and then,
/// before putting anything in it, switches it to WebM (`changeType`) for a
/// VP9 stream. WebKit on macOS 26 lets the switch through but keeps reading
/// the buffer as MP4, which takes the VP9 frames for an audio track. The page
/// gets sound and no picture, a grey box stalled half a second in, on every
/// video and after every reload. The switch fails the same way on a plain
/// page with no YouTube in it, in both directions, so it is WebKit's, not the
/// site's.
///
/// Told WebM video is out, YouTube streams MP4 (H.264, or AV1, which Apple
/// silicon from the M3 on decodes in hardware) and its buffer never changes
/// container. WebM audio, YouTube's Opus, is left alone: its buffer is made
/// for WebM from the start and plays.
///
/// Within MP4 it still changes codec, from H.264 to AV1 or back, a few seconds
/// in as it moves up in quality, and for those same accounts it does so
/// without the `changeType` the change needs. WebKit turns the new codec
/// down ("failed to process initialization segment"), and YouTube rebuilds
/// its player: every video played a few seconds, then started again. So
/// when a buffer of MP4 video is handed the start of a stream in another
/// codec, the `changeType` is made first, and WebKit plays on across it.
enum YouTubeFormats {

    /// Runs in the page's world, where the player asks, in every frame, so
    /// that embedded players are covered too. Anywhere but YouTube it returns
    /// at once and changes nothing.
    static let script = """
    (function () {
      if (!/(^|\\.)(youtube|youtube-nocookie)\\.com$/.test(location.hostname)) return;
      function webmVideo(type) {
        return /^\\s*video\\/webm\\b/i.test(String(type));
      }
      function wrap(owner, name, make) {
        if (!owner || typeof owner[name] !== 'function') return;
        try {
          Object.defineProperty(owner, name, { value: make(owner[name]), writable: true, configurable: true });
        } catch (e) {}
      }
      [window.MediaSource, window.ManagedMediaSource].forEach(function (source) {
        wrap(source, 'isTypeSupported', function (original) {
          return function isTypeSupported(type) { return !webmVideo(type) && original.call(this, type); };
        });
      });
      wrap(window.HTMLMediaElement && HTMLMediaElement.prototype, 'canPlayType', function (original) {
        return function canPlayType(type) { return webmVideo(type) ? '' : original.call(this, type); };
      });
      wrap(window.MediaCapabilities && MediaCapabilities.prototype, 'decodingInfo', function (original) {
        return function decodingInfo(configuration) {
          if (configuration && configuration.video && webmVideo(configuration.video.contentType)) {
            return Promise.resolve({ supported: false, smooth: false, powerEfficient: false, configuration: configuration });
          }
          return original.apply(this, arguments);
        };
      });

      // The codec each buffer of MP4 video was last told it holds, when made
      // or by changeType. Kept here, not on the buffer, where the page would see it.
      var told = new WeakMap();
      // A codec string of each family that WebKit takes, for the changeType.
      var stand = { avc1: 'avc1.640028', av01: 'av01.0.08M.08', vp09: 'vp09.00.40.08', hvc1: 'hvc1.1.6.L120.90' };
      function familyOf(name) {
        var four = String(name || '').slice(0, 4).toLowerCase();
        if (four === 'avc3') four = 'avc1';
        if (four === 'hev1') four = 'hvc1';
        return stand[four] ? four : null;
      }
      function mp4Video(type) { return /^\\s*video\\/mp4\\b/i.test(String(type)); }
      function typeFamily(type) {
        var codecs = /codecs\\s*=\\s*"?\\s*([^",\\s]+)/i.exec(String(type));
        return codecs ? familyOf(codecs[1]) : null;
      }
      // The video codec an MP4 initialisation segment starts: its first
      // sample entry, or for an encrypted stream the format it stands for.
      function startsCodec(data) {
        var bytes;
        try {
          bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        } catch (e) { return null; }
        var limit = Math.min(bytes.length, 65536);
        function tag(i) { return String.fromCharCode(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]); }
        function find(name, from) {
          for (var i = from; i + 4 <= limit; i++) if (bytes[i] === name.charCodeAt(0) && tag(i) === name) return i;
          return -1;
        }
        if (limit < 8 || (tag(4) !== 'ftyp' && tag(4) !== 'moov')) return null;
        var stsd = find('stsd', 8);
        if (stsd < 0 || stsd + 20 > limit) return null;
        var entry = tag(stsd + 16);
        if (entry === 'encv') {
          var frma = find('frma', stsd);
          entry = frma > 0 && frma + 8 <= limit ? tag(frma + 4) : '';
        }
        return familyOf(entry);
      }
      [window.MediaSource, window.ManagedMediaSource].forEach(function (source) {
        if (!source || !Object.prototype.hasOwnProperty.call(source.prototype, 'addSourceBuffer')) return;
        wrap(source.prototype, 'addSourceBuffer', function (original) {
          return function addSourceBuffer(type) {
            var buffer = original.apply(this, arguments);
            if (mp4Video(type)) told.set(buffer, typeFamily(type));
            return buffer;
          };
        });
      });
      [window.SourceBuffer, window.ManagedSourceBuffer].forEach(function (kind) {
        if (!kind) return;
        if (Object.prototype.hasOwnProperty.call(kind.prototype, 'changeType')) {
          wrap(kind.prototype, 'changeType', function (original) {
            return function changeType(type) {
              var result = original.apply(this, arguments);
              if (mp4Video(type)) told.set(this, typeFamily(type)); else told.delete(this);
              return result;
            };
          });
        }
        if (Object.prototype.hasOwnProperty.call(kind.prototype, 'appendBuffer')) {
          wrap(kind.prototype, 'appendBuffer', function (original) {
            return function appendBuffer(data) {
              if (told.has(this)) {
                var now = told.get(this), next = startsCodec(data);
                if (next && now && next !== now && typeof this.changeType === 'function') {
                  try { this.changeType('video/mp4; codecs="' + stand[next] + '"'); } catch (e) {}
                } else if (next && !now) {
                  told.set(this, next);
                }
              }
              return original.apply(this, arguments);
            };
          });
        }
      });
    })();
    """
}
