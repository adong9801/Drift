# Memory controls

Open **Drift → Settings… → Memory** (Command-comma), or **Tabs → Settings… → Memory**.

- The default memory budget is **2 GB**. Choose 512 MB, 1 GB, 2 GB, 4 GB, 8 GB, or Off.
- Drift checks memory every five seconds and sleeps the least recently used eligible tab when over budget. It measures again before sleeping another, aiming for ten percent of headroom.
- This is a **soft budget**, not an operating-system allocation limit. Visible/split tabs, loading pages, media, camera/microphone capture, detected unsaved form edits, and pages whose activity cannot be checked are protected. Usage can exceed the target when those tabs or extensions account for the remaining memory. The settings show that state.
- Tabs used within the last 30 seconds are protected from budget-driven sleeping. Selecting a candidate while it is being checked cancels its discard.
- Automatic idle sleeping defaults to **10 minutes**, adjustable from 5 to 60 minutes. The memory budget is independent of this switch. System memory pressure can also sleep eligible background tabs.
- Selecting a sleeping tab recreates its web view and restores WebKit's interaction state. Normal websites may reload, including network requests. Draft detection is conservative and persists until navigation.

The displayed estimate sums the physical memory footprint of Drift and its detected WebKit page, extension, graphics, and network processes, deduplicating shared PIDs. Cached processes remain counted until they exit. It does not include other browsers. Process attribution uses guarded WebKit private accessors; if unavailable or unreadable, the UI marks the reading incomplete. It is not a guaranteed total or a per-tab allocation measurement.

# Other changes

- Favicons are downsampled to 64 pixels, cached with count/cost limits, and released under memory pressure. Fresh cached icons avoid repeat downloads; concurrent requests for the same public site's icon share a fetch.
- History is written only when changed. Session/history encoding and atomic writes run on a serial utility queue, with a synchronous flush on quit.
- Thumbnail requests are throttled; JPEG encoding runs off the main thread without an intermediate TIFF.
- Cosmetic page sampling is coalesced and skipped for background tabs.
- Terminated background web processes remain asleep until selected.
- Private-session sleep timers are invalidated at session end; idle timers have scheduling tolerance.

# Verification

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache" ./Tests/run.sh
./Tests/resources.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache" ./Tests/smoke.sh
```

The AppKit/WebKit tests need a normal macOS desktop session and permission to launch helper processes. Both browser suites use scratch profiles. The resource suite uses local HTML fixtures; app startup may refresh the ad-block list. The general smoke suite also accesses public websites and local extension fixtures.

In the resource test on this machine, sleeping a background test page with a 100 MiB JavaScript allocation reduced detected total physical footprint from 380,162,368 to 211,276,096 bytes (about 44%). This verifies reclamation on a synthetic workload; it is not an Arc benchmark or a battery-life measurement. A fair Arc comparison requires matching websites, extensions, viewport, loading/idle time, and sleeping-tab policy, measuring all related processes for both browsers.

The logic and resource suites passed. The full browser smoke suite passed on rerun; its first run failed two extension-startup probe checks, while a run of the saved original code also passed. That intermittent startup behavior has not been diagnosed or claimed fixed in this memory-focused change.
