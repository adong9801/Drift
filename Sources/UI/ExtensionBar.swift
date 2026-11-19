import SwiftUI
import UniformTypeIdentifiers
import WebKit

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
            ForEach(extensions.toolbar) { record in
                ExtensionButton(record: record, extensions: extensions)
            }
            Button { managing.toggle() } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.opacity(0.85))
                    .frame(width: 26, height: 23)
                    .contentShape(Rectangle())
                    // A popup opened from the menu, for an extension whose
                    // button is not in the toolbar, hangs from here.
                    .background { PopoverAnchor(id: Extensions.menuAnchor) }
            }
            .buttonStyle(.plain)
            .help("Extensions")
            .popover(isPresented: $managing, arrowEdge: .bottom) {
                ExtensionManager(extensions: extensions, dismiss: { managing = false })
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
            Button("Hide from Toolbar") { extensions.setPinned(record, false) }
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

/// The extensions menu: one row for each extension, on top the ones that are
/// on, and the ways to install more behind the plus. A row opens its
/// extension; the pin puts its button in the toolbar or takes it out; the
/// switch turns it on and off; the rest (options, where it may run, private
/// windows, removing it) is in the row's "…" menu.
struct ExtensionManager: View {
    @ObservedObject var extensions: Extensions
    /// Puts the menu away, so that a popup opened from it is not left
    /// hanging off a menu that has gone. Nil in the menu bar's panel.
    var dismiss: (() -> Void)?
    @State private var adding = false
    @State private var link = ""
    @State private var editingSites: String?
    @State private var sitesText = ""
    @State private var removing: InstalledExtension?

    /// Those that are on first, each group in the order installed.
    private var ordered: [InstalledExtension] {
        extensions.installed.filter(\.enabled) + extensions.installed.filter { !$0.enabled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if extensions.installed.isEmpty {
                Text("None installed yet.")
                    .font(Design.body(12))
                    .foregroundStyle(Design.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 1) {
                    ForEach(ordered) { record in
                        ExtensionRow(
                            record: record,
                            extensions: extensions,
                            open: { open(record) },
                            editSites: {
                                sitesText = (record.sites ?? []).joined(separator: ", ")
                                editingSites = record.id
                            },
                            remove: { removing = record }
                        )
                        if editingSites == record.id { sitesEditor(record) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            if adding || extensions.installed.isEmpty {
                Rectangle().fill(Design.border).frame(height: 1)
                installer
            }
            if let error = extensions.lastError {
                Text(error)
                    .font(Design.body(11))
                    .foregroundStyle(Design.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
        }
        .padding(.vertical, 10)
        .frame(width: 360)
        .alert(
            "Remove \(removing.map { extensions.name(of: $0) } ?? "this extension")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let record = removing { extensions.remove(record) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("You can install it again later, but anything it has saved may be gone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Extensions")
                .font(Design.body(15, weight: .semibold))
                .foregroundStyle(Design.text)
            Spacer()
            if !extensions.installed.isEmpty {
                Button { adding.toggle() } label: {
                    Image(systemName: adding ? "xmark" : "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Design.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(adding ? "Close" : "Add an Extension")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// Where an extension that asked for every site may actually run.
    private func sitesEditor(_ record: InstalledExtension) -> some View {
        HStack(spacing: 6) {
            TextField("canvas.school.edu, *.instructure.com", text: $sitesText)
                .textFieldStyle(.roundedBorder)
                .font(Design.body(11))
                .onSubmit { saveSites(record) }
            Button("Save") { saveSites(record) }
            Button("Cancel") { editingSites = nil }
        }
        .controlSize(.small)
        .padding(.leading, 38)
        .padding(.trailing, 8)
        .padding(.bottom, 6)
    }

    private var installer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Chrome Web Store link, or a .zip, .crx or .xpi", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.body(12))
                    .onSubmit(installLink)
                Button("Install", action: installLink)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || extensions.busy)
            }
            HStack {
                Button("Choose File\u{2026}", action: chooseFile)
                    .disabled(extensions.busy)
                if extensions.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            Text("Extensions run on WebKit\u{2019}s engine, the one Safari uses. Most work; ones built on Chrome-only features may load and then do nothing.")
                .font(Design.body(11))
                .foregroundStyle(Design.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    /// Its popup if it has one, else its options page.
    private func open(_ record: InstalledExtension) {
        if record.enabled, extensions.context(record.id)?.action(for: nil) != nil {
            dismiss?()
            // Once the menu has gone, so the popup is not shut along with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.perform(record) }
        } else if extensions.context(record.id)?.optionsPageURL != nil {
            extensions.openOptions(record)
            dismiss?()
        }
    }

    private func saveSites(_ record: InstalledExtension) {
        extensions.setSites(record, sitesText.split(separator: ",").map(String.init))
        editingSites = nil
    }

    private func installLink() {
        let text = link
        Task {
            await extensions.install(fromWeb: text)
            if extensions.lastError == nil {
                link = ""
                adding = false
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked extension folder, or a .zip, .crx or .xpi."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await extensions.install(fromFile: url)
            if extensions.lastError == nil { adding = false }
        }
    }
}

/// One extension in the menu.
private struct ExtensionRow: View {
    let record: InstalledExtension
    @ObservedObject var extensions: Extensions
    let open: () -> Void
    let editSites: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var context: WKWebExtensionContext? { extensions.context(record.id) }
    private var hasPopup: Bool { record.enabled && context?.action(for: nil) != nil }
    private var hasOptions: Bool { context?.optionsPageURL != nil }

    /// "2026.9.0 · 2 sites · Private windows", short enough for one line;
    /// the sites themselves are in the line's tooltip.
    private var summary: String {
        guard record.enabled else { return "Turned off" }
        var parts: [String] = []
        let version = extensions.version(of: record)
        if !version.isEmpty { parts.append(version) }
        if extensions.asksForEverySite(record) {
            parts.append(record.sites.map { $0.count == 1 ? $0[0] : "\($0.count) sites" } ?? "All sites")
        }
        if record.allowedInPrivate == true { parts.append("Private windows") }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Group {
                        if let icon = extensions.icon(of: record, size: 20) {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "puzzlepiece.fill").resizable().foregroundStyle(Design.tertiary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .saturation(record.enabled ? 1 : 0)
                    .opacity(record.enabled ? 1 : 0.5)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(extensions.name(of: record))
                            .font(Design.body(13, weight: .medium))
                            .foregroundStyle(record.enabled ? Design.text : Design.secondary)
                            .lineLimit(1)
                        Text(summary)
                            .font(Design.body(11))
                            .monospacedDigit()
                            .foregroundStyle(Design.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasPopup && !hasOptions)
            .help([
                extensions.name(of: record),
                record.sites.map { "Runs only on " + $0.joined(separator: ", ") },
                hasPopup ? "Click to open" : hasOptions ? "Click for options" : nil,
            ].compactMap { $0 }.joined(separator: "\n"))

            if hasPopup {
                Button { extensions.setPinned(record, record.pinned == false) } label: {
                    Image(systemName: record.pinned == false ? "pin" : "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(record.pinned == false ? Design.tertiary : Design.accent)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(record.pinned == false ? "Show in Toolbar" : "Hide from Toolbar")
            }

            Toggle("", isOn: Binding(
                get: { record.enabled },
                set: { extensions.setEnabled(record, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(record.enabled ? "Turn Off" : "Turn On")

            Menu {
                if hasOptions {
                    Button("Options") { extensions.openOptions(record) }
                }
                if extensions.asksForEverySite(record) {
                    Section("Runs on") {
                        Toggle("All Sites", isOn: Binding(
                            get: { record.sites == nil },
                            set: { if $0 { extensions.setSites(record, nil) } }
                        ))
                        Toggle("Only Some Sites\u{2026}", isOn: Binding(
                            get: { record.sites != nil },
                            set: { _ in editSites() }
                        ))
                    }
                }
                Toggle("Allow in Private Windows", isOn: Binding(
                    get: { record.allowedInPrivate ?? false },
                    set: { extensions.setAllowedInPrivate(record, $0) }
                ))
                Divider()
                Button("Remove\u{2026}", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Design.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24)
            .help("More")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Design.hover : Color.clear)
        }
        .onHover { hovering = $0 }
    }
}
