import SwiftUI

/// A small calendar icon; callers provide date text in the event's own time zone.
struct CalendarDateTile: View {
    let month: String?
    let day: String?
    var size: CGFloat = Tokens.Space.s8
    var isMuted = false

    private var isCompact: Bool { size <= Tokens.Space.s8 }
    private var radius: CGFloat { isCompact ? Tokens.Radius.sm : Tokens.Radius.md }
    private var layoutSize: CGFloat { max(size, Tokens.Space.s8) }

    var body: some View {
        VStack(spacing: 0) {
            if let month, let day {
                Text(month)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isMuted ? Tokens.CalendarDate.ink : Tokens.CalendarDate.month)
                    .lineLimit(1)
                    .allowsTightening(true)
                Text(day)
                    .font(isCompact ? .title3 : .title)
                    .fontWeight(.regular)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.CalendarDate.ink)
                    .lineLimit(1)
            } else {
                Image(systemName: "calendar")
                    .font(.body)
                    .foregroundStyle(Tokens.CalendarDate.ink)
            }
        }
        .frame(width: layoutSize, height: layoutSize)
        .background(Tokens.CalendarDate.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Tokens.CalendarDate.ink.opacity(Tokens.Opacity.tint), lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .scaleEffect(size / layoutSize)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
    }
}
