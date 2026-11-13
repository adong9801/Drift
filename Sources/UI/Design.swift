import AppKit
import SwiftUI

/// The look: warm greys, one accent, hairlines, nothing that glows. The same
/// register as Ante's workspace, and it follows the system between light and
/// dark on its own.
enum Design {

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func grey(_ value: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(white: value, alpha: alpha)
    }

    /// The window behind everything: sidebar and the gutter round the page.
    static let chrome = dynamic(NSColor(red: 0.953, green: 0.951, blue: 0.941, alpha: 1), grey(0.105))
    /// Raised surfaces: the address pill, the command bar, cards.
    static let surface = dynamic(.white, grey(0.17))
    static let text = dynamic(NSColor(red: 0.216, green: 0.208, blue: 0.184, alpha: 1), grey(0.92))
    static let secondary = dynamic(NSColor(red: 0.471, green: 0.467, blue: 0.455, alpha: 1), grey(0.62))
    static let tertiary = dynamic(NSColor(red: 0.608, green: 0.604, blue: 0.592, alpha: 1), grey(0.45))
    static let border = dynamic(grey(0, 0.09), grey(1, 0.10))
    static let hover = dynamic(grey(0, 0.05), grey(1, 0.07))
    static let selected = dynamic(grey(0, 0.09), grey(1, 0.13))
    static let accent = Color.accentColor
    /// The colour of private browsing: marks private tabs and their address.
    static let privateInk = dynamic(NSColor(red: 0.42, green: 0.30, blue: 0.78, alpha: 1), NSColor(red: 0.68, green: 0.58, blue: 0.98, alpha: 1))
    static let privateSoft = dynamic(NSColor(red: 0.42, green: 0.30, blue: 0.78, alpha: 0.12), NSColor(red: 0.68, green: 0.58, blue: 0.98, alpha: 0.20))
    static let danger = dynamic(NSColor(red: 0.882, green: 0.318, blue: 0.318, alpha: 1), NSColor(red: 0.96, green: 0.42, blue: 0.42, alpha: 1))

    static let sidebarWidth: CGFloat = 208
    static let radius: CGFloat = 8
    static let pageRadius: CGFloat = 12
    /// The sidebar floats as its own rounded panel, like the bar in the icon.
    static let sidebarRadius: CGFloat = 16
    /// The gap round the floating panels, and between them.
    static let gutter: CGFloat = 8

    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Highlights a row on hover.
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? Design.hover : Color.clear)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 6) -> some View {
        modifier(HoverHighlight(radius: radius))
    }
}

/// A site icon, or a globe until one has loaded.
struct FaviconView: View {
    let image: NSImage?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .foregroundStyle(Design.tertiary)
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Lays its children out left to right, starting a new row when one would
/// not fit. Rows are as tall as their tallest child.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews, in: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(subviews, in: bounds.width)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
