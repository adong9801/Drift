import SwiftUI

struct PerformanceSettings: View {
    @ObservedObject private var memory = MemoryMonitor.shared
    @AppStorage("drift.sleepTabs.v1") private var sleepTabs = true
    @AppStorage("drift.sleepMinutes.v1") private var sleepMinutes = 10

    var body: some View {
        Form {
            Section("Memory") {
                HStack {
                    Text("Estimated memory")
                    Spacer()
                    Text(memory.usedBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "Unavailable")
                        .monospacedDigit()
                }
                Picker("Memory budget", selection: $memory.limitMB) {
                    ForEach(MemoryBudget.choices, id: \.self) { value in
                        Text(value == 0 ? "Off" : value < 1024 ? "\(value) MB" : "\(value / 1024) GB").tag(value)
                    }
                }
                Text(memory.status).foregroundStyle(.secondary)
                Text("Drift sleeps unused tabs to stay near this budget. Visible tabs, playing media, calls, and unsaved work stay awake, so usage can exceed the budget.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Includes Drift and detected page, extension, graphics, and network processes. \(memory.incomplete ? "Some processes could not be measured." : "\(memory.processCount) processes measured.")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sleeping tabs") {
                Toggle("Automatically sleep unused tabs", isOn: $sleepTabs)
                Picker("Sleep after", selection: $sleepMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { value in
                        Text("\(value) minutes").tag(value)
                    }
                }.disabled(!sleepTabs)
                Text("\(memory.sleepingCount) \(memory.sleepingCount == 1 ? "tab" : "tabs") sleeping. Selecting a sleeping tab reloads it. The memory budget can sleep tabs sooner, even when automatic sleeping is off.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Sleep Unused Tabs Now") {
                    BrowserStore.all.forEach { $0.sleepIdleTabs(olderThan: 0, force: true) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear { memory.start(); memory.refresh() }
    }
}
