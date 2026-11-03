import AppKit
import GmailAPI
import SwiftUI

struct CalendarEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CalendarEditorDraft
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
    @State private var reminders: [EditableReminder]
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmedNotifications = false
    @State private var showsOptions: Bool
    @State private var showsDetails: Bool

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
        _reminders = State(initialValue: (event.reminders?.overrides ?? []).map { EditableReminder(reminder: $0) })
        _showsOptions = State(initialValue: !(event.recurrence ?? []).isEmpty || event.reminders?.useDefault == false || !draft.importedExceptions.isEmpty)
        _showsDetails = State(initialValue: !(event.description ?? "").isEmpty || event.rawValue["source"]?.objectValue?["url"]?.stringValue != nil)
    }

    private var editable: Bool { draft.source?.canEdit ?? true }
    private var selectedCalendar: CalendarDisplayCalendar? { calendars.first { $0.id == draft.calendarKey } }
    private var eventZone: TimeZone { TimeZone(identifier: zoneID) ?? calendar.timeZone }
    private var isRecurring: Bool { draft.source?.isRecurring == true }
    private var preservesImportedDates: Bool { !draft.importedExceptions.isEmpty }
    private var eventCalendar: Calendar { var value = calendar; value.timeZone = eventZone; return value }

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    scheduleSection
                    placeSection
                    guestsSection
                    if isRecurring { scopeSection }
                    optionsSection
                    detailsSection
                }
                .padding(Tokens.Space.s5)
            }
            .disabled(isSaving)
            .environment(\.timeZone, eventZone)
            Divider()
            footer
        }
        .background(Tokens.Surface.muted)
        .frame(minWidth: Tokens.Calendar.editorWidth, idealWidth: Tokens.Calendar.editorWidth, maxWidth: .infinity,
               minHeight: Tokens.Calendar.sheetMinHeight, idealHeight: CalendarSheetLayout.height(Tokens.Calendar.editorHeight), maxHeight: .infinity)
        .interactiveDismissDisabled(isSaving)
        .onChange(of: notificationRecipients) { _, _ in confirmedNotifications = false }
        .onChange(of: draft.editScope) { _, _ in confirmedNotifications = false }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text(editable ? draft.isDeletion ? "Delete event" : draft.isNew ? "New event" : "Edit event" : "Event details")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: Tokens.Space.s4) {
                CalendarDateTile(month: CalendarLayout.format(start, style: .dateTime.month(.abbreviated), calendar: eventCalendar).uppercased(),
                                 day: "\(eventCalendar.component(.day, from: start))", size: Tokens.Space.s12)
                Spacer(minLength: 0)
                CalendarEditorCalendarPicker(selection: $draft.calendarKey, calendars: calendars)
                    .disabled(!editable || draft.isDeletion || isSaving)
            }
            TextField("Event title", text: $title, prompt: Text("Add a title"), axis: .vertical)
                .font(.title2.weight(.semibold)).textFieldStyle(.plain).lineLimit(1...3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Event title").help(title)
                .disabled(!editable || draft.isDeletion || isSaving)
            if draft.isImport {
                Text("Review your personal copy before adding it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.Space.s5)
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Label("Date & time", systemImage: "clock").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("All-day", isOn: $allDay).toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .disabled(preservesImportedDates)
                    .onChange(of: allDay) { _, value in
                        if value { start = eventCalendar.startOfDay(for: start); end = max(start, eventCalendar.startOfDay(for: end)) }
                        else { start = CalendarLayout.date(at: 9 * 60, on: start, calendar: eventCalendar); end = start.addingTimeInterval(1800) }
                    }
            }
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                CalendarEventDatePicker(title: "Starts", selection: $start, allDay: allDay, calendar: eventCalendar)
                CalendarEventDatePicker(title: allDay ? "Last day" : "Ends", selection: $end, allDay: allDay, calendar: eventCalendar)
            }
            .disabled(preservesImportedDates)
            HStack(spacing: Tokens.Space.s2) {
                if !allDay {
                    CalendarTimeZonePicker(title: "Time zone", identifier: $zoneID).font(.caption)
                        .disabled(preservesImportedDates)
                }
            }
        }
        .disabled(!editable || draft.isDeletion)
        .ternAnimation(value: allDay)
    }

    private var placeSection: some View {
        CalendarEditorCard {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary).frame(width: Tokens.Control.icon)
                TextField("Location", text: $location, prompt: Text("Add a place or address"))
                    .textFieldStyle(.plain).disabled(!editable || draft.isDeletion)
            }
            Divider()
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "video").foregroundStyle(.secondary).frame(width: Tokens.Control.icon)
                if let link = draft.event.hangoutLink ?? draft.event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
                   let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link("Join meeting", destination: url)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Add Google Meet")
                    Spacer(minLength: Tokens.Space.s3)
                    Toggle("Add Google Meet", isOn: $draft.createMeet).toggleStyle(.switch).controlSize(.mini)
                        .labelsHidden()
                        .disabled(!editable || draft.isDeletion || selectedCalendar?.entry.supportsGoogleMeet != true)
                        .help(selectedCalendar?.entry.supportsGoogleMeet == true ? "Add a video call to this event" : "This calendar does not support Google Meet")
                }
            }
        }
    }

    private var guestsSection: some View {
        CalendarEditorSection(title: attendees.isEmpty ? "Guests" : "Guests · \(attendees.count)", systemImage: "person.2") {
            CalendarEditorCard {
                ForEach($attendees, id: \.email) { $attendee in
                    HStack(spacing: Tokens.Space.s3) {
                        AddressAvatar(accountID: selectedCalendar?.accountID ?? draft.source?.accountID,
                                      address: attendee.email, name: attendee.displayName ?? "")
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(attendee.displayName ?? attendee.email).font(.callout.weight(.medium)).lineLimit(1).help(attendee.email)
                            if attendee.displayName != nil {
                                Text(attendee.email).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(attendee.email)
                            }
                            Label(Self.responseTitle(attendee.responseStatus), systemImage: Self.responseSymbol(attendee.responseStatus))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Tokens.Space.s2)
                        Toggle("Optional", isOn: $attendee.optional.or(false)).toggleStyle(.checkbox).font(.caption).fixedSize()
                        Button { attendees.removeAll { $0.email == attendee.email } } label: {
                            Image(systemName: "xmark").font(.caption).frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        }
                        .buttonStyle(.plain).ternHover().help("Remove guest")
                        .accessibilityLabel("Remove \(attendee.displayName ?? attendee.email)")
                    }
                    .disabled(draft.isDeletion)
                    Divider()
                }
                if attendees.isEmpty {
                    HStack(spacing: Tokens.Space.s3) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text("Invite someone").font(.callout.weight(.medium))
                            Text("Add guests by email.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: Tokens.Space.s2) {
                    TextField("Guest email address", text: $newAttendee).textFieldStyle(.roundedBorder).onSubmit(addAttendee)
                    Button("Add", systemImage: "plus", action: addAttendee)
                        .disabled(newAttendee.trimmingCharacters(in: .whitespaces).isEmpty)
                }.disabled(draft.isDeletion)
                if !notificationRecipients.isEmpty, !draft.isImport {
                    Divider()
                    Toggle(draft.isDeletion ? "Send cancellations to guests" : "Send invitations or updates to guests", isOn: $confirmedNotifications)
                        .toggleStyle(.checkbox).font(.callout)
                    Text("To: \(notificationRecipients.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.disabled(!editable)
    }

    private var scopeSection: some View {
        CalendarEditorSection(title: "Apply changes to", systemImage: "arrow.triangle.branch") {
            CalendarEditorCard {
                Picker("Events", selection: $draft.editScope) {
                    ForEach(CalendarEditScope.allCases) { scope in
                        Text(scope.title).tag(scope).disabled(scope != .occurrence && draft.seriesMaster == nil)
                    }
                }.disabled(draft.recovery != nil)
                if draft.seriesMaster == nil {
                    Text("Series details are unavailable. Refresh before editing all or following events.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.editScope == .following {
                    Text(draft.isDeletion ? "This event and all following occurrences will be deleted." : (knownExceptionCount ?? draft.followingExceptionsCount).map { "This splits the series. \($0) later exceptions may be reset." }
                         ?? "This splits the series. Later exceptions may be reset; Tern checks the series before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("I have reviewed the change to following events", isOn: $draft.acknowledgesFollowingReset).toggleStyle(.checkbox)
                }
            }
        }.disabled(!editable).ternAnimation(value: draft.editScope)
    }

    private var optionsSection: some View {
        CalendarEditorCard {
            DisclosureGroup(isExpanded: $showsOptions) {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    CalendarRecurrenceControl(rules: $recurrence, allDay: allDay, timeZone: eventZone)
                        .disabled(preservesImportedDates || (isRecurring && draft.editScope == .occurrence))
                    if !draft.importedExceptions.isEmpty {
                        Text("This import includes ^[\(draft.importedExceptions.count) changed or cancelled occurrence](inflect: true). Dates and repeat rules are preserved. You can edit them after import.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("Use calendar alerts", isOn: $useDefaultAlerts).toggleStyle(.switch).controlSize(.mini)
                    if !useDefaultAlerts {
                        ForEach($reminders) { $row in
                            HStack {
                                Picker("Method", selection: $row.reminder.method) {
                                    Text("Notification").tag("popup"); Text("Email").tag("email")
                                }.labelsHidden().accessibilityLabel("Alert method")
                                TextField("Minutes before", value: $row.reminder.minutes, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: Tokens.Space.s16)
                                Text("minutes before").font(.caption).foregroundStyle(.secondary).fixedSize()
                                Spacer(minLength: 0)
                                Button { reminders.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove alert").accessibilityLabel("Remove alert")
                            }
                        }
                        Button("Add alert", systemImage: "plus") { reminders.append(EditableReminder(reminder: CalendarReminder(minutes: 10))) }
                            .disabled(reminders.count >= 5)
                    }
                }.padding(.top, Tokens.Space.s3)
                    .disabled(!editable || draft.isDeletion)
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Label("Repeat & alerts", systemImage: "repeat").font(.callout.weight(.medium))
                    if !showsOptions {
                        Text("\(recurrence.isEmpty ? "Does not repeat" : "Repeating event") · \(useDefaultAlerts ? "Calendar alerts" : reminders.isEmpty ? "No alerts" : "Custom alerts")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, Tokens.Space.s1)
            }
        }
        .ternAnimation(value: useDefaultAlerts).ternAnimation(value: reminders.map(\.id))
    }

    private var detailsSection: some View {
        CalendarEditorCard {
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    Picker("Show as", selection: $draft.event.transparency.or("opaque")) {
                        Text("Busy").tag("opaque"); Text("Free").tag("transparent")
                    }
                    Picker("Visibility", selection: $draft.event.visibility.or("default")) {
                        Text("Calendar default").tag("default"); Text("Private").tag("private"); Text("Public").tag("public")
                    }
                    TextField("URL", text: $eventURL, prompt: Text("Add a link")).textFieldStyle(.roundedBorder)
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes).scrollContentBackground(.hidden)
                        .frame(minHeight: Tokens.Space.s16 + Tokens.Space.s4).accessibilityLabel("Event notes")
                        .padding(Tokens.Space.s2).ternSurface(radius: Tokens.Radius.md)
                }.disabled(!editable || draft.isDeletion).padding(.top, Tokens.Space.s3)
            } label: {
                Label("Notes & details", systemImage: "text.alignleft").font(.callout.weight(.medium))
                    .padding(.vertical, Tokens.Space.s1)
            }
            ForEach(draft.event.attachments ?? []) { attachment in
                if let url = URL(string: attachment.fileUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link(destination: url) { Label(attachment.title ?? "Attachment", systemImage: "paperclip") }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: Tokens.Space.s3) {
            if let error { CalendarInlineError(message: error).ternTransition(.disclosure) }
            HStack(spacing: Tokens.Space.s3) {
                if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving event") }
                if !editable, let link = draft.event.htmlLink, let url = URL(string: link), url.scheme == "https" {
                    Link("Open in Google Calendar", destination: url).font(.caption)
                } else {
                    Label(scheduleSummary, systemImage: allDay ? "sun.max" : "clock").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Tokens.Space.s2)
                Button(editable ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                if editable {
                    Button(saveTitle ?? (draft.isDeletion ? "Delete event" : draft.isImport ? "Add to calendar" : "Save"), role: draft.isDeletion ? .destructive : nil) { commit() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(isSaving || !canSave)
                }
            }.controlSize(.large)
        }
        .padding(.horizontal, Tokens.Space.s6).padding(.vertical, Tokens.Space.s4)
        .ternAnimation(value: error != nil)
    }

    private var scheduleSummary: String {
        if allDay {
            let days = max(1, (eventCalendar.dateComponents([.day], from: eventCalendar.startOfDay(for: start), to: eventCalendar.startOfDay(for: end)).day ?? 0) + 1)
            return days == 1 ? "All-day event" : "\(days) days · All-day"
        }
        guard end > start else { return "Check event times" }
        return Duration.seconds(end.timeIntervalSince(start)).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
    }

    private static func responseSymbol(_ status: String?) -> String {
        switch status { case "accepted": "checkmark.circle"; case "declined": "xmark.circle"; case "tentative": "questionmark.circle"; default: "clock" }
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
        guard reminders.allSatisfy({ (0...40320).contains($0.reminder.minutes) }) else { error = "Alerts must be between 0 and 40,320 minutes before the event."; return }
        if !eventURL.isEmpty {
            guard let url = URL(string: eventURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { error = "Enter a complete http or https URL."; return }
        }
        var output = draft
        var values = CalendarEditorValues(event: draft.event, calendar: calendar)
        values.title = title; values.location = location; values.notes = notes; values.url = eventURL
        values.start = start; values.end = end; values.allDay = allDay; values.timeZoneID = zoneID
        values.recurrence = recurrence; values.attendees = attendees
        values.usesDefaultAlerts = useDefaultAlerts; values.reminders = reminders.map(\.reminder)
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
            .font(.callout).foregroundStyle(Tokens.Status.error)
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
