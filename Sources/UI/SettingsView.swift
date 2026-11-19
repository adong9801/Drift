import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PerformanceSettings()
                .tabItem { Label("Memory", systemImage: "memorychip") }
        }
        .frame(width: 520, height: 610)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var browser = DefaultBrowser.shared
    @AppStorage("drift.switcherGrouping.v1") private var grouping = SwitcherGrouping.stacked.rawValue
    @AppStorage(SteadyScrolling.userDefaultsKey) private var steadyScrolling = true

    var body: some View {
        Form {
            Section("Scrolling") {
                Toggle("Keep the text you're reading still", isOn: $steadyScrolling)
                    .onChange(of: steadyScrolling) { _, on in
                        BrowserStore.all.flatMap(\.tabs).forEach { $0.setSteadyScrolling(on) }
                    }
                Text("When a page adds or removes something above what you're reading, as long ChatGPT chats do while you scroll, the page stays put instead of jumping. Chrome and Firefox do the same.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Tab groups") {
                Picker("Groups in Ctrl-Tab", selection: $grouping) {
                    ForEach(SwitcherGrouping.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Text(grouping == SwitcherGrouping.rows.rawValue
                     ? "Your latest tabs in a row, then a row for each group."
                     : grouping == SwitcherGrouping.off.rawValue
                     ? "Every tab on its own card, as if there were no groups."
                     : "A collapsed group is one stacked card. Press G in Ctrl-Tab, or click the stack's button, to expand or collapse it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Default browser") {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(browser.isDefault ? "Drift is your default browser" : "Make Drift your default browser")
                            .font(.headline)
                        Text("Open web links from other apps in Drift.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !browser.isDefault {
                    Button(browser.requesting ? "Waiting for macOS…" : "Make Default") {
                        Task { await browser.request() }
                    }
                    .disabled(browser.requesting)
                    Text("macOS will ask you to confirm the change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = browser.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { browser.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            browser.refresh()
        }
    }
}
