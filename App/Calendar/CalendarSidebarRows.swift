import SwiftUI

struct CalendarSidebarEventRow: View {
    let event: CalendarDisplayEvent
    let calendar: Calendar
    var showsDate = false
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            RoundedRectangle(cornerRadius: Tokens.Space.s0_5)
                .fill(event.color)
                .frame(width: Tokens.Space.s1)
            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                if showsDate {
                    Text(CalendarLayout.format(event.start, style: .dateTime.weekday(.abbreviated).month(.abbreviated).day(), calendar: calendar))
                        .font(.callout.bold()).foregroundStyle(.secondary)
                }
                Text(event.isAllDay ? "All day" : timeRange)
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(event.title).font(.body.bold()).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if event.isPending {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityLabel("Waiting to sync")
                    }
                }
                if let location = event.event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(event.color.opacity(Tokens.Calendar.eventTint), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, focus: isSelected ? .accentColor : nil)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }

    private var timeRange: String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: event.start, to: event.end)
    }
}

struct CalendarSidebarEmptyDay: View {
    let model: CalendarModel

    private var hasVisibleCalendars: Bool { model.calendars.contains(where: \.isVisible) }
    private var isLoading: Bool { model.isLoading || model.sidebarIsLoading }
    private var isUnverified: Bool { model.sidebarPresentation == nil || model.sidebarHasStaleEvents }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(spacing: Tokens.Space.s2) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: hasVisibleCalendars ? "calendar" : "calendar.badge.minus")
                        .foregroundStyle(.secondary)
                }
                Text(title).font(.headline)
            }
            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
    }

    private var title: String {
        if !hasVisibleCalendars { return "No calendars selected" }
        if isLoading { return "Loading events…" }
        if isUnverified { return "No cached events" }
        return model.calendar.isDateInToday(model.date) ? "No events today" : "No events this day"
    }

    private var message: String {
        if !hasVisibleCalendars { return "Select a calendar above to see its events." }
        if isLoading { return "Checking the calendars you have selected." }
        if isUnverified { return "Refresh Calendar to check this day." }
        return "Dots under a date mark days with events."
    }
}

struct CalendarSidebarSyncStatus: View {
    let model: CalendarModel

    var body: some View {
        Group {
            if model.isLoading || model.sidebarIsLoading {
                HStack(spacing: Tokens.Space.s1_5) {
                    ProgressView().controlSize(.mini)
                        .frame(width: Tokens.Control.icon, height: Tokens.Control.icon)
                        .accessibilityHidden(true)
                    Text("Updating…")
                }
            } else if model.errorMessage != nil {
                status("Update failed", symbol: "exclamationmark.triangle.fill", tint: Tokens.Status.warning)
            } else if model.operations.contains(where: { $0.status == .failed || $0.status == .conflicted }) {
                status("Changes need review", symbol: "exclamationmark.circle", tint: Tokens.Status.warning)
            } else if model.operations.contains(where: { $0.status == .queued || $0.status == .running }) {
                status("Sync pending", symbol: "clock", tint: Tokens.Status.warning)
            } else if !model.calendars.contains(where: \.isVisible) {
                status(model.calendars.isEmpty ? "No calendars" : "Calendars hidden", symbol: "calendar")
            } else if model.hasStaleEvents || model.sidebarHasStaleEvents {
                status("Cached events", symbol: "exclamationmark.circle", tint: Tokens.Status.warning)
            } else if let date = model.lastCheckedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let relative = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
                    ViewThatFits(in: .horizontal) {
                        status("Updated \(relative)", symbol: "checkmark.circle", tint: Tokens.Status.success)
                            .fixedSize(horizontal: true, vertical: false)
                        status(relative, symbol: "checkmark.circle", tint: Tokens.Status.success)
                    }
                    .help("Last updated \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            } else {
                status("Not updated yet", symbol: "circle.dashed")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func status(_ title: String, symbol: String, tint: Color = .secondary) -> some View {
        HStack(spacing: Tokens.Space.s1_5) {
            Image(systemName: symbol).foregroundStyle(tint)
                .frame(width: Tokens.Control.icon).accessibilityHidden(true)
            Text(title)
        }
    }
}
