# Drift

A small macOS browser built on WebKit.

- Split view, private windows, and a Ctrl-Tab switcher
- Chrome extensions, installed from a Chrome Web Store link
- Built-in ad blocking
- Background tabs sleep to stay within a memory budget (see [PERFORMANCE.md](PERFORMANCE.md))
- A playing video follows you into picture in picture when you leave its tab, and comes back when you return

## Download

Get **Drift.zip** from the [latest release](https://github.com/adong9801/Drift/releases/latest), unzip it, and move Drift to Applications. It needs a Mac with Apple silicon and macOS 15.4 or later.

Drift isn't notarized by Apple, so macOS blocks it the first time. To open it anyway, try opening it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run this in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Drift.app
```

## Build

```sh
./build.sh
```

The app lands in `.build/Drift.app`. There's no Xcode project; the script compiles `Sources/` with `swiftc`, so only the Xcode command line tools are needed.

## Tests

See [Tests/README.md](Tests/README.md).
