import SwiftUI

struct CalendarTimelineEvent: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.calendarIdentities) private var identities
    let event: CalendarDisplayEvent
    let selected: Bool
    let height: CGFloat
    let calendar: Calendar
    var showsRange = false

    var body: some View {
        styledCard
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(tooltip)
    }

    private var styledCard: some View {
        layoutCard
            .background(fillColor, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay(alignment: .leading) { colorStripe }
            .overlay { outline }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private var layoutCard: some View {
        content
            .padding(.vertical, Tokens.Space.s1)
            .padding(.horizontal, Tokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: max(Tokens.Space.s6, height))
            .foregroundStyle(Color.primary)
    }

    private var colorStripe: some View {
        Capsule().fill(event.color)
            .frame(width: Tokens.Space.s0_5)
            .padding(.vertical, Tokens.Space.s1)
    }

    private var outline: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .strokeBorder(outlineColor, lineWidth: Tokens.Border.focus)
    }

    private var outlineColor: Color { selected ? Color.accentColor : Color.clear }
    private var fillColor: Color {
        event.color.opacity(CalendarColor.tint(selected ? Tokens.Calendar.selectedTint : Tokens.Calendar.allDayTint, contrast: contrast))
    }
    private var calendarTitle: String { identities.title(for: event.calendarKey) }
    private var showsSeparateCalendarTitle: Bool { differentiate && height >= Tokens.Space.s16 }
    private var accessibilityDescription: String { String(localized: "\(event.title), \(calendarTitle), \(timeDescription)") }
    private var tooltip: String { "\(event.title)\n\(calendarTitle)\n\(timeDescription)" }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            headline
            if showsSeparateCalendarTitle {
                Text(calendarTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if height >= Tokens.Space.s12 || showsRange { details }
            Spacer(minLength: 0)
        }
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s1) {
            Text(differentiate && !showsSeparateCalendarTitle
                 ? String(localized: "\(calendarTitle): \(event.title)") : event.title)
                .font(.caption.weight(.semibold))
                .lineLimit(height >= Tokens.Space.s16 && (!differentiate || height >= Tokens.Space.s16 + Tokens.Space.s4) ? 2 : 1)
            if event.isPending {
                Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            Text(showsRange ? rangeDescription : CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            if height > Tokens.Space.s16 + Tokens.Space.s4, let location = event.event.location, !location.isEmpty {
                Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var rangeDescription: String {
        CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar)
            + " – " + CalendarLayout.format(event.end, style: .dateTime.hour().minute(), calendar: calendar)
    }

    private var timeDescription: String {
        CalendarLayout.format(event.start, style: .dateTime.month().day().hour().minute(), calendar: calendar)
            + " – " + CalendarLayout.format(event.end, style: .dateTime.month().day().hour().minute(), calendar: calendar)
            + (event.isPending ? ", pending sync" : "")
    }
}
