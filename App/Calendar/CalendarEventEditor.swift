import AppKit
import GmailAPI
import SwiftUI

struct CalendarEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: CalendarEditorDraft
    let calendars: [CalendarDisplayCalendar]
    let calendar: Calendar
    let save: (CalendarEditorDraft) async throws -> Void
    let knownExceptionCount: Int?
    let saveTitle: String?
    let additionalRecipients: [String]
    @State private var title: String
    @State private var location: String
    @State private var notes: String
    @State private var eventURL: String
    @State private var start: Date
    @State private var end: Date
    @State private var allDay: Bool
    @State private var zoneID: String
    @State private var recurrence: [String]
    @State private var attendees: [CalendarAttendee]
    @State private var newAttendee = ""
    @State private var useDefaultAlerts: Bool
    @State private var reminders: [CalendarReminder]
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmedNotifications = false

    init(draft: CalendarEditorDraft, calendars: [CalendarDisplayCalendar], calendar: Calendar,
         knownExceptionCount: Int? = nil, saveTitle: String? = nil, additionalRecipients: [String] = [], save: @escaping (CalendarEditorDraft) async throws -> Void) {
        self.knownExceptionCount = knownExceptionCount
        self.saveTitle = saveTitle
        self.additionalRecipients = additionalRecipients
        _draft = State(initialValue: draft); self.calendars = calendars; self.calendar = calendar; self.save = save
        let event = draft.event
        let start = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? .now
        let exclusiveEnd = event.end?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? start.addingTimeInterval(1800)
        _title = State(initialValue: event.summary ?? "")
        _location = State(initialValue: event.location ?? "")
        _notes = State(initialValue: event.description ?? "")
        _eventURL = State(initialValue: event.rawValue["source"]?.objectValue?["url"]?.stringValue ?? "")
        _start = State(initialValue: start)
        _end = State(initialValue: event.isAllDay ? calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start : exclusiveEnd)
        _allDay = State(initialValue: event.isAllDay)
        _zoneID = State(initialValue: event.start?.timeZone ?? calendar.timeZone.identifier)
        _recurrence = State(initialValue: event.recurrence ?? [])
        _attendees = State(initialValue: event.attendees ?? [])
        _useDefaultAlerts = State(initialValue: event.reminders?.useDefault ?? true)
        _reminders = State(initialValue: event.reminders?.overrides ?? [])
    }

    private var editable: Bool { draft.source?.canEdit ?? true }
    private var selectedCalendar: CalendarDisplayCalendar? { calendars.first { $0.id == draft.calendarKey } }
    private var eventZone: TimeZone { TimeZone(identifier: zoneID) ?? calendar.timeZone }
    private var isRecurring: Bool { draft.source?.isRecurring == true }
    private var preservesImportedDates: Bool { !draft.importedExceptions.isEmpty }
    private var eventCalendar: Calendar { var value = calendar; value.timeZone = eventZone; return value }

    var body: some View {
        VStack(spacing: 0) {
            CalendarSheetHeading(
                title: editable ? draft.isDeletion ? "Delete event" : draft.isNew ? "New event" : "Edit event" : "Event details",
                subtitle: draft.isImport ? "Review your personal copy before adding it." : selectedCalendar.map { "\($0.accountName) · \($0.title)" } ?? "",
                systemImage: draft.isDeletion ? "calendar.badge.minus" : "calendar",
                color: selectedCalendar?.color ?? .accentColor
            )
            Divider()
            Form {
                Section("Event") {
                    TextField("Title", text: $title, prompt: Text("Add a title"))
                        .font(.title3.weight(.medium))
                    Picker("Calendar", selection: $draft.calendarKey) {
                        ForEach(calendars.filter { $0.canWrite || $0.id == draft.calendarKey }) { calendar in
                            Text("\(calendar.accountName) · \(calendar.title)").tag(calendar.id)
                        }
                    }
                    TextField("Location", text: $location, prompt: Text("Add a place or address"))
                }.disabled(draft.isDeletion)
                Section("Date & time") {
                    Toggle("All-day", isOn: $allDay)
                        .onChange(of: allDay) { _, value in
                            if value { start = eventCalendar.startOfDay(for: start); end = max(start, eventCalendar.startOfDay(for: end)) }
                            else { start = CalendarLayout.date(at: 9 * 60, on: start, calendar: eventCalendar); end = start.addingTimeInterval(1800) }
                        }
                        .disabled(preservesImportedDates)
                    DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                        .disabled(preservesImportedDates)
                    DatePicker(allDay ? "Last day" : "Ends", selection: $end, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                        .disabled(preservesImportedDates)
                    if !allDay {
                        TextField("Time zone", text: $zoneID)
                            .help("Use an IANA time zone, such as Europe/Vienna.")
                            .disabled(preservesImportedDates)
                    }
                }.disabled(draft.isDeletion)
                if isRecurring {
                    Section("Apply changes to") {
                        Picker("Events", selection: $draft.editScope) {
                            ForEach(CalendarEditScope.allCases) { scope in
                                Text(scope.title).tag(scope).disabled(scope != .occurrence && draft.seriesMaster == nil)
                            }
                        }
                        if draft.seriesMaster == nil {
                            Text("Series details are unavailable. Refresh before editing all or following events.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if draft.editScope == .following {
                            Text(draft.isDeletion ? "This event and all following occurrences will be deleted." : (knownExceptionCount ?? draft.followingExceptionsCount).map { "This splits the series. \($0) later exceptions may be reset." }
                                 ?? "This splits the series. Later exceptions may be reset; Tern checks the series before saving.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("I have reviewed the change to following events", isOn: $draft.acknowledgesFollowingReset)
                        }
                    }
                }
                Section("Repeat") {
                    CalendarRecurrenceControl(rules: $recurrence, allDay: allDay, timeZone: eventZone)
                        .disabled(preservesImportedDates || (isRecurring && draft.editScope == .occurrence))
                    if !draft.importedExceptions.isEmpty {
                        Text("This import includes \(draft.importedExceptions.count) changed or cancelled occurrences.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Dates and repeat rules are preserved with those occurrences. You can edit them after import.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(draft.isDeletion)
                Section("Guests") {
                    if attendees.isEmpty {
                        Label("No guests added", systemImage: "person.2")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(attendees.enumerated()), id: \.offset) { index, attendee in
                        HStack {
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(attendee.displayName ?? attendee.email).lineLimit(1).help(attendee.email)
                                if attendee.displayName != nil { Text(attendee.email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Text(Self.responseTitle(attendee.responseStatus)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Tokens.Space.s2)
                            Toggle("Optional", isOn: Binding(get: { attendees[index].optional == true }, set: { attendees[index].optional = $0 })).toggleStyle(.checkbox).disabled(draft.isDeletion)
                            Button { attendees.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove guest").accessibilityLabel("Remove \(attendee.displayName ?? attendee.email)").disabled(draft.isDeletion)
                        }
                    }
                    HStack {
                        TextField("Guest email address", text: $newAttendee).onSubmit(addAttendee)
                        Button("Add", action: addAttendee).disabled(newAttendee.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.disabled(draft.isDeletion)
                    if !notificationRecipients.isEmpty, !draft.isImport {
                        Text("\(draft.isDeletion ? "Deleting sends cancellations" : "Saving sends invitations or updates") to: \(notificationRecipients.joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle(draft.isDeletion ? "Send cancellations to these guests" : "Send invitations or updates to these guests", isOn: $confirmedNotifications)
                    }
                }
                Section("Video call") {
                    if let link = draft.event.hangoutLink ?? draft.event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
                       let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(destination: url) { Label("Join meeting", systemImage: "video") }
                            .buttonStyle(.bordered)
                    } else {
                        Toggle("Add Google Meet", isOn: $draft.createMeet).disabled(selectedCalendar?.entry.supportsGoogleMeet != true)
                        if selectedCalendar?.entry.supportsGoogleMeet != true {
                            Text("This calendar does not support Google Meet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(draft.isDeletion)
                Section("Alerts") {
                    Toggle("Use calendar defaults", isOn: $useDefaultAlerts)
                    if !useDefaultAlerts {
                        ForEach(Array(reminders.enumerated()), id: \.offset) { index, reminder in
                            HStack {
                                Picker("Method", selection: Binding(get: { reminders[index].method }, set: { reminders[index].method = $0 })) {
                                    Text("Notification").tag("popup"); Text("Email").tag("email")
                                }
                                TextField("Minutes before", value: Binding(get: { reminders[index].minutes }, set: { reminders[index].minutes = $0 }), format: .number).frame(width: Tokens.Space.s16)
                                Text("minutes before").font(.caption).foregroundStyle(.secondary).fixedSize()
                                Button { reminders.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove alert").accessibilityLabel("Remove alert")
                            }.id("\(index)-\(reminder.method)")
                        }
                        Button("Add alert") { reminders.append(CalendarReminder(minutes: 10)) }.disabled(reminders.count >= 5)
                    }
                }.disabled(draft.isDeletion)
                Section {
                    Picker("Show as", selection: Binding(get: { draft.event.transparency ?? "opaque" }, set: { draft.event.transparency = $0 })) {
                        Text("Busy").tag("opaque"); Text("Free").tag("transparent")
                    }
                    Picker("Visibility", selection: Binding(get: { draft.event.visibility ?? "default" }, set: { draft.event.visibility = $0 })) {
                        Text("Calendar default").tag("default"); Text("Private").tag("private"); Text("Public").tag("public")
                    }
                    TextField("URL", text: $eventURL)
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Text("Notes").font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: $notes)
                            .frame(minHeight: Tokens.Space.s16 + Tokens.Space.s4)
                            .accessibilityLabel("Event notes")
                    }
                    ForEach(draft.event.attachments ?? []) { attachment in
                        if let url = URL(string: attachment.fileUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(attachment.title ?? "Attachment", destination: url)
                        }
                    }
                } header: { Text("Details") }
                    .disabled(draft.isDeletion)
            }
            .formStyle(.grouped).disabled(!editable || isSaving)
            .environment(\.timeZone, eventZone)
            Divider()
            VStack(spacing: Tokens.Space.s3) {
                if let error { CalendarInlineError(message: error) }
                HStack(spacing: Tokens.Space.s3) {
                    if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving event") }
                    if !editable, let link = draft.event.htmlLink, let url = URL(string: link), url.scheme == "https" {
                        Link("Open in Google Calendar", destination: url)
                    }
                    Spacer()
                    Button(editable ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                    if editable {
                        Button(saveTitle ?? (draft.isDeletion ? "Delete event" : draft.isImport ? "Add to calendar" : "Save"), role: draft.isDeletion ? .destructive : nil) { commit() }
                            .keyboardShortcut(.defaultAction).disabled(isSaving || !canSave)
                    }
                }
            }.padding(Tokens.Space.s4)
                .background(Tokens.Surface.muted)
        }
        .frame(width: Tokens.Calendar.editorWidth, height: CalendarSheetLayout.height(Tokens.Calendar.editorHeight))
        .interactiveDismissDisabled(isSaving)
        .onChange(of: notificationRecipients) { _, _ in confirmedNotifications = false }
        .onChange(of: draft.editScope) { _, _ in confirmedNotifications = false }
    }

    private var notificationRecipients: [String] {
        Array(Set((attendees + (draft.source?.event.attendees ?? [])).map(\.email) + draft.additionalNotificationRecipients + additionalRecipients)).sorted()
    }
    private var canSave: Bool {
        selectedCalendar?.canWrite == true && (!isRecurring || draft.editScope != .following || draft.acknowledgesFollowingReset)
            && (!isRecurring || draft.editScope != .following || (knownExceptionCount ?? draft.followingExceptionsCount) != nil)
            && (notificationRecipients.isEmpty || draft.isImport || confirmedNotifications)
    }
    private func addAttendee() {
        let address = newAttendee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), !address.contains(where: \.isWhitespace), address.split(separator: "@").count == 2 else {
            error = "Enter a complete email address."; return
        }
        guard !attendees.contains(where: { $0.email.caseInsensitiveCompare(address) == .orderedSame }) else { newAttendee = ""; return }
        attendees.append(CalendarAttendee(email: address, responseStatus: "needsAction")); newAttendee = ""; error = nil
    }
    private func commit() {
        if draft.isDeletion { submit(draft); return }
        guard let zone = TimeZone(identifier: zoneID) else { error = "Choose a valid time zone."; return }
        guard allDay ? end >= start : end > start else { error = "The end must be after the start."; return }
        guard reminders.allSatisfy({ (0...40320).contains($0.minutes) }) else { error = "Alerts must be between 0 and 40,320 minutes before the event."; return }
        if !eventURL.isEmpty {
            guard let url = URL(string: eventURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { error = "Enter a complete http or https URL."; return }
        }
        var output = draft
        var values = CalendarEditorValues(event: draft.event, calendar: calendar)
        values.title = title; values.location = location; values.notes = notes; values.url = eventURL
        values.start = start; values.end = end; values.allDay = allDay; values.timeZoneID = zoneID
        values.recurrence = recurrence; values.attendees = attendees
        values.usesDefaultAlerts = useDefaultAlerts; values.reminders = reminders
        output.event = values.applying(to: draft.event, calendar: calendar, timeZone: zone)
        submit(output)
    }
    private func submit(_ output: CalendarEditorDraft) {
        isSaving = true; error = nil
        Task { @MainActor in
            do { try await save(output); dismiss() }
            catch { self.error = error.localizedDescription; isSaving = false }
        }
    }
    private static func responseTitle(_ status: String?) -> String {
        switch status { case "accepted": "Accepted"; case "declined": "Declined"; case "tentative": "Maybe"; default: "Awaiting reply" }
    }
}

struct CalendarSheetHeading: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            Image(systemName: systemImage)
                .font(.title2).foregroundStyle(color)
                .frame(width: Tokens.Control.avatarLarge, height: Tokens.Control.avatarLarge)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.title2.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s5)
        .background(Tokens.Surface.muted)
    }
}

struct CalendarInlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

enum CalendarSheetLayout {
    @MainActor static func height(_ preferred: CGFloat) -> CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        return min(preferred, (screen?.visibleFrame.height ?? (preferred + Tokens.Space.s16)) - Tokens.Space.s16)
    }
}
