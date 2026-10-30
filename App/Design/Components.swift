import SwiftUI

/// A compact label whose text remains legible independently of its accent color.
struct TernBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1)
        .background(Tokens.Surface.muted, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : Tokens.Surface.border,
                              lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Initials accompany an already visible sender or account name.
struct TernAvatar: View {
    let name: String
    var size: CGFloat = Tokens.Control.avatar

    var body: some View {
        Group {
            if initials.isEmpty {
                Image(systemName: "person.fill")
            } else {
                Text(initials)
            }
        }
        .font(size > Tokens.Control.avatar ? .headline : .caption.weight(.semibold))
        // Keep initials legible on the neutral disc when a native list selects its row.
        .foregroundStyle(Color(nsColor: .labelColor))
        .frame(width: size, height: size)
        .background(Tokens.Surface.muted, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let displayName = String(name.prefix { $0 != "<" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let localName = displayName.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let words = localName.split { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }
        guard let first = words.first else { return "" }
        if words.count > 1, let last = words.last {
            return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }
}

struct TernEmptyState: View {
    let title: String
    let systemImage: String
    let message: String
    var fillsSpace = true

    var body: some View {
        VStack(spacing: Tokens.Space.s4) {
            Image(systemName: systemImage)
                .font(.largeTitle.weight(.light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                .accessibilityHidden(true)
            VStack(spacing: Tokens.Space.s2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: Tokens.Layout.emptyStateWidth)
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
        .accessibilityElement(children: .combine)
    }
}

private struct TernSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(contrast == .increased ? Color.primary : Tokens.Surface.border,
                                  lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
    }
}

private struct TernAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Tokens.Motion.standard(), value: value)
    }
}

extension View {
    /// Adds a card surface without clipping controls or their focus rings.
    func ternSurface() -> some View { modifier(TernSurface()) }

    func ternAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(TernAnimation(value: value))
    }
}
