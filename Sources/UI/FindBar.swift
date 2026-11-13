import SwiftUI

/// Incremental, case-insensitive find. WebKit performs the search so it can
/// reach rendered text in frames as well as ordinary HTML.
struct FindBar: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var finder: PageFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Design.tertiary)
            TextField("Find on page", text: $finder.query)
                .textFieldStyle(.plain)
                .font(Design.body(13))
                .foregroundStyle(finder.result == .missing ? Design.danger : Design.text)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { finder.next(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .accessibilityLabel("Find on page")
            Text(status)
                .font(Design.body(11))
                .foregroundStyle(finder.result == .missing ? Design.danger : Design.secondary)
                .frame(minWidth: 72, alignment: .trailing)
                .accessibilityLabel(status)
            Toggle("Aa", isOn: $finder.caseSensitive)
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("Match case")
                .accessibilityLabel("Match case")
            Button { finder.next(backwards: true) } label: { icon("chevron.up") }
                .disabled(finder.query.isEmpty)
                .help("Previous match (Shift-Return or Shift-Command-G)")
                .accessibilityLabel("Previous match")
            Button { finder.next() } label: { icon("chevron.down") }
                .disabled(finder.query.isEmpty)
                .help("Next match (Return or Command-G)")
                .accessibilityLabel("Next match")
            Button {
                store.dismissFind()
            } label: { icon("xmark") }
                .help("Close find (Escape)")
                .accessibilityLabel("Close find")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: Design.radius, style: .continuous)
                .fill(Design.surface)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Design.radius, style: .continuous).strokeBorder(Design.border, lineWidth: 1)
        }
        .onAppear { finder.present(); focusAndSelect() }
        .onChange(of: finder.focusRequest) { _, _ in focusAndSelect() }
        .onDisappear { finder.dismiss() }
    }

    private func focusAndSelect() {
        focused = true
        DispatchQueue.main.async {
            guard store.findVisible, store.focused?.finder === finder, focused else { return }
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private var status: String {
        switch finder.result {
        case .idle: return ""
        case .searching: return "Searching…"
        case .found: return "Match found"
        case .missing: return "No matches"
        case .unavailable: return "Page unavailable"
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Design.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .hoverHighlight(radius: 5)
    }
}
