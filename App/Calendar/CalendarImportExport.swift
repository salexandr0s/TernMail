import AppKit
import GmailAPI
import MessageContent
import SwiftUI
import UniformTypeIdentifiers

struct CalendarImportItem: Identifiable {
    var id = UUID()
    var event: GoogleCalendarEvent
    var exceptions: [GoogleCalendarEvent] = []
}

enum CalendarImportExport {
    static func read(_ url: URL) throws -> [CalendarImportItem] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw ImportError.tooLarge }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> [CalendarImportItem] {
        guard data.count <= 4 * 1024 * 1024 else { throw ImportError.tooLarge }
        return try CalendarInterchange.importGroups(data).map { group in
            guard let master = group.master else { throw CalendarInterchangeError.recurrenceExceptionNeedsSeries }
            let event = try CalendarInterchange.googleEvent(from: master)
            let exceptions = try group.exceptions.map {
                try CalendarInterchange.googleException(from: $0, parentEventID: "pending-import")
            }
            return CalendarImportItem(event: event, exceptions: exceptions)
        }
    }

    static func string(for events: [GoogleCalendarEvent]) throws -> String {
        let data = try CalendarInterchange.exportEvents(events)
        guard let value = String(data: data, encoding: .utf8) else { throw ImportError.invalidEncoding }
        return value
    }

    /// Copying creates a personal duplicate. It must not retain the source's
    /// meeting identity, guests, or a conference shared with another event.
    static func clipboardString(for event: GoogleCalendarEvent) throws -> String {
        var copy = standaloneOccurrence(event)
        for key in ["id", "organizer", "creator", "attendees", "conferenceData", "hangoutLink", "etag", "extendedProperties"] {
            copy.rawValue[key] = nil
        }
        copy.iCalUID = UUID().uuidString + "@tern"
        return try string(for: [copy])
    }

    static func standaloneOccurrence(_ event: GoogleCalendarEvent) -> GoogleCalendarEvent {
        guard event.recurringEventId != nil else { return event }
        var copy = event
        copy.iCalUID = event.id + "@tern-occurrence"
        for key in ["recurringEventId", "originalStartTime", "recurrence"] { copy.rawValue[key] = nil }
        return copy
    }

    @MainActor static func save(_ events: [GoogleCalendarEvent]) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        panel.nameFieldStringValue = "Calendar.ics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = try CalendarInterchange.exportEvents(events)
        try data.write(to: url, options: .atomic)
    }

    @MainActor static func printEvents(_ events: [CalendarDisplayEvent], title: String) {
        let lines = events.sorted { $0.start < $1.start }.map { event in
            let date = event.start.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)
            let location = event.event.location.map { "\n\($0)" } ?? ""
            return "\(date)  \(event.title)\(location)"
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        text.isEditable = false
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.string = title + "\n\n" + lines.joined(separator: "\n\n")
        text.font = NSFont.systemFont(ofSize: 12)
        if let container = text.textContainer, let layout = text.layoutManager {
            container.containerSize = NSSize(width: 468, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            text.setFrameSize(NSSize(width: 500, height: max(700, layout.usedRect(for: container).height + 32)))
        }
        let operation = NSPrintOperation(view: text)
        operation.printInfo.horizontalPagination = .fit
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    enum ImportError: Error, LocalizedError {
        case tooLarge, invalidEncoding
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose a calendar file smaller than 4 MB."
            case .invalidEncoding: "The calendar file could not be encoded."
            }
        }
    }
}

struct CalendarImportReview: View {
    @Environment(\.dismiss) private var dismiss
    @State var events: [CalendarImportItem]
    let calendars: [CalendarDisplayCalendar]
    let save: ([CalendarImportItem], String) async throws -> Void
    @State private var calendarKey = ""
    @State private var selected = Set<UUID>()
    @State private var isSaving = false
    @State private var error: String?
    @State private var editing: CalendarEditorDraft?
    @State private var editingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            CalendarSheetHeading(title: "Import events", subtitle: "Review personal copies. Importing does not send invitations or RSVPs.", systemImage: "square.and.arrow.down")
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Picker("Add to", selection: $calendarKey) {
                    ForEach(calendars.filter(\.canWrite)) { calendar in Text("\(calendar.accountName) · \(calendar.title)").tag(calendar.id) }
                }
                HStack {
                    Text("\(selected.count) of \(events.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Select all") { selected = Set(events.filter { !$0.event.isCancelled }.map(\.id)) }
                    Button("Deselect all") { selected.removeAll() }
                }.buttonStyle(.borderless).disabled(isSaving || events.isEmpty)
                if calendars.allSatisfy({ !$0.canWrite }) {
                    Label("Choose a calendar you can edit before importing.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(Tokens.Space.s4)
                .disabled(isSaving)
            Divider()
            List(events) { item in
                HStack {
                    Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { included in
                        if included { selected.insert(item.id) } else { selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(item.event.title).font(.headline)
                            if let start = item.event.startDate { Text(start.formatted(date: .abbreviated, time: item.event.isAllDay ? .omitted : .shortened)).font(.caption) }
                            if !item.exceptions.isEmpty { Text("Repeats, with \(item.exceptions.count) changed or cancelled occurrences").font(.caption).foregroundStyle(.secondary) }
                            if item.event.isCancelled { Text("Cancelled event").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.toggleStyle(.checkbox).disabled(item.event.isCancelled || isSaving)
                    Spacer()
                    Button("Edit…") {
                        editingID = item.id
                        editing = CalendarEditorDraft(event: item.event, calendarKey: calendarKey, isImport: true, importedExceptions: item.exceptions)
                    }.disabled(item.event.isCancelled || isSaving)
                }.padding(.vertical, Tokens.Space.s2)
            }.listStyle(.inset)
                .overlay {
                    if events.isEmpty {
                        TernEmptyState(title: "No events to import", systemImage: "calendar", message: "This file contains no events.")
                    }
                }
            Divider()
            VStack(spacing: Tokens.Space.s3) {
                if let error { CalendarInlineError(message: error) }
                HStack(spacing: Tokens.Space.s3) {
                    if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Importing events") }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                    Button("Add \(selected.count) events") {
                        isSaving = true; error = nil
                        Task { @MainActor in
                            do { try await save(events.filter { selected.contains($0.id) }, calendarKey); dismiss() }
                            catch { self.error = error.localizedDescription; isSaving = false }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(isSaving || selected.isEmpty || calendarKey.isEmpty)
                }
            }.padding(Tokens.Space.s4).background(Tokens.Surface.muted)
        }.frame(width: Tokens.Calendar.editorWidth, height: CalendarSheetLayout.height(Tokens.Calendar.activityHeight))
            .onAppear { calendarKey = calendars.first(where: \.canWrite)?.id ?? ""; selected = Set(events.filter { !$0.event.isCancelled }.map(\.id)) }
            .interactiveDismissDisabled(isSaving)
            .sheet(item: $editing) { draft in
                CalendarEventEditor(draft: draft, calendars: calendars.filter { $0.id == calendarKey }, calendar: .current, saveTitle: "Done") { reviewed in
                    guard let index = events.firstIndex(where: { $0.id == editingID }) else { return }
                    events[index].event = reviewed.event
                    events[index].exceptions = reviewed.importedExceptions
                    editing = nil
                }
            }
    }
}
