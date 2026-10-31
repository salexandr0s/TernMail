import SwiftUI

struct CalendarSearchResults: View {
    let events: [CalendarDisplayEvent]
    let calendar: Calendar
    @Binding var selectedID: String?
    let edit: (CalendarDisplayEvent) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    var body: some View {
        if events.isEmpty {
            TernEmptyState(title: "No matching events", systemImage: "magnifyingglass", message: "Try another title or location, or choose a different date window.")
        } else {
            List(events, selection: $selectedID) { event in
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
                .onTapGesture(count: 2) { edit(event) }
                .help(event.title)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selectedID == event.id ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { edit(event) }
                .contextMenu {
                    Button("Open Event") { edit(event) }
                    Button("Duplicate") { duplicate(event) }
                    Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                if let event = events.first(where: { $0.id == selectedID }), event.canEdit { delete(event) }
            }
            .onKeyPress(.return) {
                guard let event = events.first(where: { $0.id == selectedID }) else { return .ignored }
                edit(event)
                return .handled
            }
        }
    }
}
