import AppKit

/// Runs inside a separate test bundle/profile. The `open` subprocess delivers
/// real Launch Services URL events to the app's normal delegate.
@MainActor enum LinkProbe {
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func start() {
        Task { @MainActor in
            let store = BrowserStore.shared
            for _ in 0..<80 {
                if store.window != nil && Extensions.shared.isReady { break }
                await pause(0.1)
            }
            await pause(0.5)
            var results: [[String: Any]] = []
            func record(_ name: String, _ pass: Bool) {
                results.append(["name": name, "passed": pass])
                try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    .write(to: Storage.directory.appendingPathComponent("launch-progress.json"))
            }
            func open(_ suffixes: [String]) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-g", "-a", Bundle.main.bundlePath] + suffixes.map { "https://example.com/#drift-\($0)" }
                try? process.run()
            }
            @MainActor func selected(_ suffix: String) -> Bool {
                store.selected?.url?.fragment == "drift-\(suffix)"
            }
            @MainActor func visible() -> Bool {
                store.window?.isVisible == true && store.window?.isMiniaturized == false
            }
            record("cold launch receives URL", selected("cold"))
            record("cold launch shows browser window", visible())

            open(["warm"])
            await pause(1.5)
            record("running app receives URL", selected("warm"))

            store.window?.miniaturize(nil)
            await pause(0.7)
            record("fixture minimizes browser", store.window?.isMiniaturized == true)
            open(["minimized"])
            await pause(1.5)
            record("minimized app receives URL", selected("minimized"))
            record("external link restores minimized window", visible())

            store.window?.deminiaturize(nil)
            NSApp.hide(nil)
            await pause(0.3)
            open(["hidden"])
            await pause(1.5)
            record("external link reveals hidden app", selected("hidden") && visible() && !NSApp.isHidden)

            store.commandBar = .current
            await pause(0.3)
            open(["overlay"])
            await pause(1.5)
            record("external link dismisses address overlay", selected("overlay") && store.commandBar == nil)

            open(["batch-one", "batch-two"])
            await pause(1.5)
            record("multiple external URLs each open once", ["batch-one", "batch-two"].allSatisfy { suffix in
                store.tabs.filter { $0.url?.fragment == "drift-\(suffix)" }.count == 1
            })
            let destination = Storage.directory.appendingPathComponent("launch-result.json")
            try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
            NSApp.terminate(nil)
        }
    }
}
