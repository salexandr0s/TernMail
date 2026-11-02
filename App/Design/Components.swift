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

/// Photos and logos retain their proportions and transparent edges.
struct AvatarImage: View {
    let image: NSImage
    var size: CGFloat = Tokens.Control.avatar

    private var fittedSize: CGSize {
        let factor = min(size / max(image.size.width, 1), size / max(image.size.height, 1))
        return CGSize(width: image.size.width * factor, height: image.size.height * factor)
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: fittedSize.width, height: fittedSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius(for: min(fittedSize.width, fittedSize.height)), style: .continuous))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func cornerRadius(for size: CGFloat) -> CGFloat {
        Tokens.Radius.sm * size / Tokens.Control.avatar
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

    private var initials: String { AvatarInitials.from(name: name) }
}

struct TernEmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
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
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: Tokens.Layout.emptyStateWidth)
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
        .accessibilityElement(children: .combine)
    }
}

/// How an outline shows at normal contrast. Under Increase Contrast every
/// outline draws in `Color.primary`.
enum TernOutlineStyle {
    /// A separator-colored hairline.
    case hairline
    /// Nothing, for filled shapes that already stand apart.
    case contrastOnly
}

private struct TernOutline: ViewModifier {
    let radius: CGFloat
    let style: TernOutlineStyle
    let focus: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if let color {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(color, lineWidth: focus == nil ? Tokens.Border.hairline : Tokens.Border.focus)
                    .allowsHitTesting(false)
            }
        }
    }

    private var color: Color? {
        if let focus { return focus }
        if contrast == .increased { return .primary }
        return style == .hairline ? Tokens.Surface.border : nil
    }
}

/// `.content` panels sit on window backgrounds. `.grouped` panels match the
/// sections of a grouped form, so they tint in dark mode and outline only
/// under Increase Contrast.
enum TernSurfaceStyle {
    case content, grouped
}

private struct TernSurface: ViewModifier {
    let radius: CGFloat
    let style: TernSurfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .ternOutline(radius: radius, style: style == .grouped ? .contrastOnly : .hairline)
    }

    private var fill: Color {
        style == .grouped && colorScheme == .dark ? Color.primary.opacity(Tokens.Settings.groupTint) : Tokens.Surface.primary
    }
}

private struct TernAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Tokens.Motion.standard(), value: value)
    }
}

/// Hover feedback for rows and chips that act on a click. The tint fades
/// unless Reduce Motion is on.
private struct TernHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let isEnabled: Bool
    let radius: CGFloat
    let pointer: PointerStyle?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? Tokens.Opacity.hover : 0))
                    .animation(reduceMotion ? nil : Tokens.Motion.standard(duration: Tokens.Motion.fast), value: isHovered)
                    .transaction { transaction in
                        if !isEnabled || reduceMotion {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
            .pointerStyle(pointer)
    }
}

extension View {
    /// Adds a card surface without clipping controls or their focus rings.
    func ternSurface(radius: CGFloat = Tokens.Radius.lg, style: TernSurfaceStyle = .content) -> some View {
        modifier(TernSurface(radius: radius, style: style))
    }

    /// A rounded outline that follows Increase Contrast. A `focus` color, when
    /// set, replaces it at focus width.
    func ternOutline(radius: CGFloat, style: TernOutlineStyle = .hairline, focus: Color? = nil) -> some View {
        modifier(TernOutline(radius: radius, style: style, focus: focus))
    }

    func ternAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(TernAnimation(value: value))
    }

    /// Highlights the view under the pointer. Pass `.link` for views that open something.
    func ternHover(isEnabled: Bool = true, radius: CGFloat = Tokens.Radius.sm, pointer: PointerStyle? = nil) -> some View {
        modifier(TernHover(isEnabled: isEnabled, radius: radius, pointer: pointer))
    }

    /// The resize pointer for a divider or grip that moves along `axis`.
    func ternResizeCursor(_ axis: Axis) -> some View {
        pointerStyle(axis == .horizontal ? .columnResize(directions: .all) : .rowResize(directions: .all))
    }

    /// Asks before a destructive action. `message` says what happens to the data.
    func ternConfirm(_ title: String, isPresented: Binding<Bool>, actionTitle: String, message: String,
                     action: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(actionTitle, role: .destructive, action: action)
        } message: {
            Text(message)
        }
    }

    /// Asks before a destructive action on `item`. Dismissing clears it.
    func ternConfirm<Item>(_ title: String, item: Binding<Item?>, actionTitle: String, message: String,
                           action: @escaping (Item) -> Void) -> some View {
        confirmationDialog(
            title,
            isPresented: item.isPresent(),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { value in
            Button(actionTitle, role: .destructive) {
                action(value)
                item.wrappedValue = nil
            }
        } message: { _ in
            Text(message)
        }
    }
}
