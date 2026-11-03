import SwiftUI

struct CalendarSearchResults: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.calendarIdentities) private var identities
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    let events: [CalendarDisplayEvent]
    let calendar: Calendar
    @Binding var selectedID: String?
    let edit: (CalendarDisplayEvent) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    var body: some View {
        if events.isEmpty {
            TernEmptyState(title: "No Matching Events", systemImage: "magnifyingglass", message: "Try another title or location, or choose a different date window.")
        } else {
            List(events, selection: $selectedID) { event in
                let calendarTitle = identities.title(for: event.calendarKey)
                let description = eventDescription(event, calendarTitle: calendarTitle)
                HStack(spacing: Tokens.Space.s3) {
                    VStack(spacing: Tokens.Space.s0_5) {
                        Text(CalendarLayout.format(event.start, style: .dateTime.month(.abbreviated), calendar: calendar))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(calendar.component(.day, from: event.start))")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                    }
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    Capsule().fill(event.color).frame(width: Tokens.Space.s1, height: Tokens.Space.s10)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        HStack(spacing: Tokens.Space.s2) {
                            Text(event.title).font(.headline).lineLimit(1)
                            if event.isPending { Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary).help("Pending sync") }
                        }
                        if differentiate {
                            Text(calendarTitle).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(CalendarLayout.format(event.start, style: .dateTime.weekday(.wide).month(.abbreviated).day().year(), calendar: calendar))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let location = event.event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: Tokens.Space.s2)
                    VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                        if event.isAllDay {
                            Text("All day").font(.callout.weight(.medium))
                        } else {
                            Text(CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar))
                                .font(.callout.weight(.medium)).monospacedDigit()
                            Text(CalendarLayout.format(event.end, style: .dateTime.hour().minute(), calendar: calendar))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.fixedSize()
                }
                .padding(.vertical, Tokens.Space.s2).tag(event.id)
                .contentShape(Rectangle())
                .ternHover()
                .draggable(CalendarEventTransfer(event))
                .onTapGesture(count: 2) { if isEnabled { edit(event) } }
                .help(description)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(description)
                .accessibilityAddTraits(selectedID == event.id ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { if isEnabled { edit(event) } }
                .contextMenu { CalendarEventMenuItems(event: event, edit: edit, duplicate: duplicate, delete: delete) }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                if isEnabled, let event = events.first(where: { $0.id == selectedID }), event.canEdit { delete(event) }
            }
            .onKeyPress(.return) {
                guard isEnabled, let event = events.first(where: { $0.id == selectedID }) else { return .ignored }
                edit(event)
                return .handled
            }
        }
    }

    private func eventDescription(_ event: CalendarDisplayEvent, calendarTitle: String) -> String {
        let dates = CalendarEventDateDescription.text(start: event.start, end: event.end, isAllDay: event.isAllDay, calendar: calendar)
        var parts = [event.title, calendarTitle, dates]
        if event.isAllDay { parts.append(String(localized: "All day")) }
        if let location = event.event.location, !location.isEmpty { parts.append(location) }
        if event.isPending { parts.append(String(localized: "Pending sync")) }
        return parts.joined(separator: ", ")
    }
}
