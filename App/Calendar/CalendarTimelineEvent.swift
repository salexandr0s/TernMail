import SwiftUI

struct CalendarTimelineEvent: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.calendarIdentities) private var identities
    @Environment(\.calendarPresentation) private var presentation
    let event: CalendarDisplayEvent
    let selected: Bool
    let height: CGFloat
    let calendar: Calendar
    var showsRange = false
    /// True in an overlap lane narrower than `Tokens.Calendar.compactCardWidth`,
    /// where the usual side padding would leave the title no room.
    var isCompact = false

    #if TERN_TEST_SUPPORT
    static var onBodyEvaluation: ((CalendarTimelineEvent) -> Void)?
    #endif

    var body: some View {
        #if TERN_TEST_SUPPORT
        let _ = Self.onBodyEvaluation?(self)
        #endif
        // The tooltip and the VoiceOver label share one description of the time.
        let time = timeDescription
        let accessibilityDescription = String(localized: "\(event.title), \(calendarTitle), \(time)")
        let tooltip = "\(event.title)\n\(calendarTitle)\n\(time)"
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
            .padding(.horizontal, isCompact ? Tokens.Space.s1 : Tokens.Space.s2)
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
    /// The dates the snapshot formatted for this event. A card it did not lay
    /// out, such as the preview of a drag, has none and formats its own.
    private var prepared: CalendarPresentationSnapshot.CardDates? {
        presentation?.cardDates(for: event, calendar: calendar)
    }

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
            Text(showsRange ? rangeDescription
                 : prepared?.start ?? CalendarEventDateDescription.cardStart(event, calendar: calendar))
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
        prepared?.range ?? CalendarEventDateDescription.cardRange(event, calendar: calendar)
    }
}
