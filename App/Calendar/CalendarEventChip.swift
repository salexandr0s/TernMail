import SwiftUI

struct CalendarEventChip: View {
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.calendarIdentities) private var identities
    let event: CalendarDisplayEvent
    var selected = false
    var showsTime = true
    /// The grab pointer while the chip can be moved; nil keeps the arrow.
    var pointer: PointerStyle?

    var body: some View {
        content
            .padding(.horizontal, Tokens.Space.s1_5)
            .frame(height: Tokens.Space.s6)
            .foregroundStyle(Color.primary)
            .background(event.color.opacity(CalendarColor.tint(tint, contrast: contrast)), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(outlineColor, lineWidth: Tokens.Border.focus) }
            .contentShape(Rectangle())
            .ternHover(pointer: pointer)
            .help("\(event.title)\n\(calendarTitle)\n\(dateDescription)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "\(event.title), \(calendarTitle), \(dateDescription)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var content: some View {
        HStack(spacing: Tokens.Space.s1) {
            Capsule().fill(event.color).frame(width: Tokens.Space.s0_5, height: Tokens.Space.s3)
            Text(differentiate ? String(localized: "\(calendarTitle): \(event.title)") : event.title)
                .font(.caption.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            if showsTime {
                Text(event.start, style: .time).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if event.isPending { Image(systemName: "clock.arrow.circlepath").font(.caption2) }
        }
    }

    private var tint: Double {
        if selected { return Tokens.Calendar.selectedTint }
        return event.isAllDay ? Tokens.Calendar.allDayTint : Tokens.Calendar.eventTint
    }

    private var outlineColor: Color { selected ? .accentColor : .clear }
    private var calendarTitle: String { identities.title(for: event.calendarKey) }

    private var dateDescription: String {
        event.start.formatted(Date.FormatStyle(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened, timeZone: timeZone))
            + (event.isAllDay ? ", all day" : " – " + event.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)))
            + (event.isPending ? ", pending sync" : "")
    }
}
