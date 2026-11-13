import SwiftUI

struct CalendarEventChip: View {
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.calendarIdentities) private var identities
    @Environment(\.calendarPresentation) private var presentation
    let event: CalendarDisplayEvent
    var selected = false
    var showsTime = true
    /// The grab pointer while the chip can be moved; nil keeps the arrow.
    var pointer: PointerStyle?

    var body: some View {
        // The tooltip and the VoiceOver label share one description of the dates.
        let dates = dateDescription
        content
            .padding(.horizontal, Tokens.Space.s1_5)
            .frame(height: Tokens.Space.s6)
            .foregroundStyle(Color.primary)
            .background(event.color.opacity(CalendarColor.tint(tint, contrast: contrast)), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(outlineColor, lineWidth: Tokens.Border.focus) }
            .contentShape(Rectangle())
            .ternHover(pointer: pointer)
            .help("\(event.title)\n\(calendarTitle)\n\(dates)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "\(event.title), \(calendarTitle), \(dates)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if showsTime {
            // In a narrow month cell the time would leave the title a letter
            // or two. The time goes first; the tooltip still has it.
            ViewThatFits(in: .horizontal) {
                row(time: true)
                row(time: false)
            }
        } else {
            row(time: false)
        }
    }

    private func row(time: Bool) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            Capsule().fill(event.color).frame(width: Tokens.Space.s0_5, height: Tokens.Space.s3)
            Text(differentiate ? String(localized: "\(calendarTitle): \(event.title)") : event.title)
                .font(.caption.weight(.medium)).lineLimit(1)
                // The row with a time is measured with fixed widths for the
                // title and the time, so every chip in a month changes at the
                // same cell width whatever its title or hour. Neither width
                // changes how the chosen row is laid out.
                .frame(idealWidth: time ? Tokens.Calendar.chipTitleMinWidth : nil, alignment: .leading)
            Spacer(minLength: 0)
            if time {
                Text(event.start, style: .time).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(idealWidth: Tokens.Calendar.chipTimeWidth, alignment: .trailing)
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

    /// The snapshot's text for this event, or the same text made here for a
    /// chip the snapshot did not prepare.
    private var dateDescription: String {
        presentation?.chipDates(for: event, timeZone: timeZone)
            ?? CalendarEventDateDescription.chip(event, timeZone: timeZone)
    }
}
