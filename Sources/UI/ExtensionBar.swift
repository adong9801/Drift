import SwiftUI
import UniformTypeIdentifiers

/// The extensions' buttons, and the puzzle piece that opens the manager. Sits
/// at the foot of the sidebar, or in the top bar when the sidebar is hidden.
struct ExtensionBar: View {
    @ObservedObject var extensions = Extensions.shared
    /// What to draw the icons in. The top bar passes the page's ink.
    var ink: Color = Design.secondary
    @State private var managing = false

    var body: some View {
        // A Group, not a stack: whatever holds the bar lays the buttons out,
        // and the sidebar's footer wraps them when they do not fit in a row.
        Group {
            ForEach(extensions.actionable) { record in
                ExtensionButton(record: record, extensions: extensions)
            }
            Button { managing.toggle() } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.opacity(0.85))
                    .frame(width: 26, height: 23)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Extensions")
            .popover(isPresented: $managing, arrowEdge: .bottom) {
                ExtensionManager(extensions: extensions)
            }
            // The sidebar may only be peeking out; it must stay while the
            // manager hangs off it, or the manager goes with it.
            .onChange(of: managing) { _, open in BrowserStore.shared.peekHeld = open }
        }
        // Not given `.id(extensions.revision)`: a badge changing, which uBlock
        // does on every page load, would remake the whole bar and close the
        // manager mid-click. Observing `extensions` already redraws the buttons.
    }
}

private struct ExtensionButton: View {
    let record: InstalledExtension
    @ObservedObject var extensions: Extensions

    var body: some View {
        let action = extensions.context(record.id)?.action(for: BrowserStore.shared.focused)
        Button { extensions.perform(record) } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = extensions.icon(of: record, size: 16) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.fill").resizable().foregroundStyle(Design.tertiary)
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 26, height: 23)

                if let badge = action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background { Capsule().fill(Design.danger) }
                        .offset(x: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
            // The popup is an AppKit popover and needs a real view to point at.
            .background { PopoverAnchor(id: record.id) }
        }
        .buttonStyle(.plain)
        .opacity(action?.isEnabled == false ? 0.4 : 1)
        .help(action?.label.isEmpty == false ? action!.label : extensions.name(of: record))
        .contextMenu {
            if extensions.context(record.id)?.optionsPageURL != nil {
                Button("Options") { extensions.openOptions(record) }
            }
            Button("Turn Off") { extensions.setEnabled(record, false) }
        }
    }
}

private struct PopoverAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Extensions.shared.registerAnchor(view, for: id)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Extensions.shared.registerAnchor(view, for: id)
    }
}

// MARK: - Manager

/// What is installed, and the ways to install more: a Chrome Web Store link, a
/// direct link to an archive, or a file or folder on disk.
struct ExtensionManager: View {
    @ObservedObject var extensions: Extensions
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extensions")
                .font(Design.body(15, weight: .semibold))
                .foregroundStyle(Design.text)

            if extensions.installed.isEmpty {
                Text("None installed. Paste a Chrome Web Store link below, or choose an extension you have downloaded.")
                    .font(Design.body(12))
                    .foregroundStyle(Design.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(extensions.installed) { record in
                        row(record)
                        if extensions.asksForEverySite(record) { sitesRow(record) }
                        privateRow(record)
                    }
                }
            }

            Rectangle().fill(Design.border).frame(height: 1)

            HStack(spacing: 6) {
                TextField("Chrome Web Store link, or a link to a .zip, .crx or .xpi", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.body(12))
                    .onSubmit(installLink)
                Button("Install", action: installLink)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || extensions.busy)
            }
            HStack {
                Button("Install from File\u{2026}", action: chooseFile)
                    .disabled(extensions.busy)
                if extensions.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)

            if let error = extensions.lastError {
                Text(error)
                    .font(Design.body(11))
                    .foregroundStyle(Design.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Extensions run on WebKit\u{2019}s engine, the one Safari uses. Most work; ones built on Chrome-only features may load and then do nothing.")
                .font(Design.body(11))
                .foregroundStyle(Design.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
    }

    private func row(_ record: InstalledExtension) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = extensions.icon(of: record, size: 20) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.fill").resizable().foregroundStyle(Design.tertiary)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(extensions.name(of: record))
                    .font(Design.body(13, weight: .medium))
                    .foregroundStyle(record.enabled ? Design.text : Design.secondary)
                    .lineLimit(1)
                if !extensions.version(of: record).isEmpty {
                    Text(extensions.version(of: record))
                        .font(Design.body(11))
                        .monospacedDigit()
                        .foregroundStyle(Design.tertiary)
                }
            }
            Spacer(minLength: 0)

            if extensions.context(record.id)?.optionsPageURL != nil {
                Button("Options") { extensions.openOptions(record) }
                    .controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { record.enabled },
                set: { extensions.setEnabled(record, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button { extensions.remove(record) } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.secondary)
            .help("Remove")
        }
        .padding(.vertical, 5)
    }

    /// Whether it may see and run in private windows. Off by default.
    private func privateRow(_ record: InstalledExtension) -> some View {
        Toggle(isOn: Binding(
            get: { record.allowedInPrivate ?? false },
            set: { extensions.setAllowedInPrivate(record, $0) }
        )) {
            Text("Allow in private windows")
                .font(Design.body(11))
                .foregroundStyle(Design.tertiary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.leading, 30)
        .padding(.bottom, 6)
    }

    /// For an extension that asked to read every site: where it actually runs.
    private func sitesRow(_ record: InstalledExtension) -> some View {
        SitesField(record: record, extensions: extensions)
            .padding(.leading, 30)
            .padding(.bottom, 6)
    }

    private func installLink() {
        let text = link
        Task {
            await extensions.install(fromWeb: text)
            if extensions.lastError == nil { link = "" }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked extension folder, or a .zip, .crx or .xpi."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await extensions.install(fromFile: url) }
    }
}

/// "Runs on: all sites" with a field to narrow it to a few hosts.
private struct SitesField: View {
    let record: InstalledExtension
    @ObservedObject var extensions: Extensions
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                TextField("canvas.school.edu, *.instructure.com", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.body(11))
                    .onSubmit(commit)
                Button("Save", action: commit).controlSize(.small)
                Button("All sites") { extensions.setSites(record, nil); editing = false }.controlSize(.small)
            } else {
                Text(record.sites.map { "Runs on \($0.joined(separator: ", "))" } ?? "Runs on all sites")
                    .font(Design.body(11))
                    .foregroundStyle(Design.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change\u{2026}") { text = (record.sites ?? []).joined(separator: ", "); editing = true }
                    .buttonStyle(.plain)
                    .font(Design.body(11))
                    .foregroundStyle(Design.accent)
            }
            Spacer(minLength: 0)
        }
    }

    private func commit() {
        extensions.setSites(record, text.split(separator: ",").map(String.init))
        editing = false
    }
}
