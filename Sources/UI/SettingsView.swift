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

    var body: some View {
        Form {
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
