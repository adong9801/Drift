import SwiftUI

/// The one place anything is typed: addresses, searches, and the name of a tab
/// you already have open. The first row is what Return does.
struct CommandBar: View {
    @ObservedObject var store: BrowserStore
    let mode: CommandBarMode

    @State private var text = ""
    @State private var remote: [String] = []
    @State private var highlighted = 0
    @State private var lookup: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// The list on show. Kept, not computed: building it walks the whole
    /// history, and `body` and the key handlers would each pay for that again.
    @State private var rows: [Suggestion] = []

    private func buildRows() -> [Suggestion] {
        Suggest.build(
            input: text,
            tabs: store.tabs.map { Suggest.OpenTab(id: $0.id, title: $0.title, url: $0.url?.absoluteString ?? "") },
            history: store.history,
            learned: store.shortcuts,
            remote: remote,
            excluding: mode == .current ? store.focused?.id : nil
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .onTapGesture { store.dismissCommandBar() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: mode == .split ? "rectangle.split.2x1" : (isPrivate ? "eye.slash" : "magnifyingglass"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Design.tertiary)
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(Design.body(18))
                        .foregroundStyle(Design.text)
                        .focused($focused)
                        .onSubmit { submit(rows) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if isPrivate {
                    Text("Private: not saved to history, not remembered, no search guesses sent.")
                        .font(Design.body(11))
                        .foregroundStyle(Design.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                if !rows.isEmpty {
                    Rectangle().fill(Design.border).frame(height: 1)
                    VStack(alignment: .leading, spacing: 1) {
                        if text.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Most visited")
                                .font(Design.body(11, weight: .semibold))
                                .foregroundStyle(Design.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            SuggestionRow(row: row, favicon: favicon(for: row), lit: index == highlighted)
                                .onTapGesture { store.run(row, typed: text) }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 640)
            // Frosted, so the page stays in view behind it.
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Design.border, lineWidth: 1)
            }
            .padding(.top, 120)
        }
        .onAppear {
            // Cmd-L starts from the current address, selected, so typing
            // replaces it and Cmd-C copies it.
            if mode == .current, let url = store.focused?.url { text = url.absoluteString }
            focused = true
            rows = buildRows()
            store.onArrow = { down in
                let count = rows.count
                guard count > 0 else { return }
                highlighted = (highlighted + (down ? 1 : -1) + count) % count
            }
            store.onForget = {
                guard rows.indices.contains(highlighted) else { return }
                store.forget(rows[highlighted])
                rows = buildRows()
                highlighted = min(highlighted, max(0, rows.count - 1))
            }
            if mode == .current {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        }
        .onDisappear {
            store.onArrow = nil
            store.onForget = nil
            lookup?.cancel()
        }
        .onChange(of: text) { _, latest in
            highlighted = 0
            rows = buildRows()
            fetchGuesses(for: latest)
        }
        .onChange(of: remote) { _, _ in rows = buildRows() }
    }

    /// Everything typed in the private window's bar is private.
    private var isPrivate: Bool { store.isPrivateWindow }

    private var placeholder: String {
        switch mode {
        case .newTab: return "Search, enter an address, or find a tab"
        case .current: return "Search or enter an address"
        case .split: return "Open alongside\u{2026}"
        }
    }

    private func submit(_ rows: [Suggestion]) {
        if rows.indices.contains(highlighted) {
            store.run(rows[highlighted], typed: text)
        } else if let url = Address.destination(for: text) {
            store.run(Suggestion(kind: .address, title: text, subtitle: "", action: .open(url)))
        }
    }

    private func favicon(for row: Suggestion) -> NSImage? {
        switch row.action {
        case .switchTo(let id): return store.tab(id)?.favicon
        case .open(let url):
            return row.kind == .history || row.kind == .learned ? url.host.flatMap(FaviconCache.shared.cached(host:)) : nil
        }
    }

    /// Search guesses, a beat after typing stops. Skipped for anything that
    /// reads as an address: there is nothing to guess, and no reason to send
    /// it anywhere.
    private func fetchGuesses(for input: String) {
        lookup?.cancel()
        let query = input.trimmingCharacters(in: .whitespaces)
        // Never from a private bar: guesses mean sending each keystroke to the
        // search engine, before anything has been searched for.
        guard !isPrivate, query.count >= 2, Address.url(from: query) == nil else {
            remote = []
            return
        }
        lookup = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled,
                  var parts = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            else { return }
            parts.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
            guard let url = parts.url, let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled
            else { return }
            // The endpoint sometimes answers in Latin-1, which JSON parsing
            // would reject outright.
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            remote = Suggest.parseRemote(Data(text.utf8))
        }
    }
}

private struct SuggestionRow: View {
    let row: Suggestion
    let favicon: NSImage?
    let lit: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let favicon {
                    FaviconView(image: favicon)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(lit ? Color.white : Design.tertiary)
                }
            }
            .frame(width: 18, height: 18)

            Text(row.title)
                .font(Design.body(14, weight: .medium))
                .foregroundStyle(lit ? Color.white : Design.text)
                .lineLimit(1)
            Text(row.subtitle)
                .font(Design.body(12))
                .foregroundStyle(lit ? Color.white.opacity(0.8) : Design.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if lit {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Design.accent : Color.clear)
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch row.kind {
        case .tab: return "square.on.square"
        case .learned: return "arrow.up.right"
        case .history: return "clock"
        case .address: return "globe"
        case .search: return "magnifyingglass"
        }
    }
}
