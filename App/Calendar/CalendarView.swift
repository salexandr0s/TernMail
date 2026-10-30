import AppKit
import GmailAPI
import SwiftUI
import UniformTypeIdentifiers

struct CalendarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CalendarModel
    var isActive = true
    @State private var showManagement = false
    @State private var showActivity = false
    @State private var showImport = false
    @State private var importEvents: [CalendarImportItem] = []
    @State private var showImportReview = false
    @State private var deleteTarget: CalendarDisplayEvent?
    @State private var showDatePicker = false
    @State private var showCalendarList = false
    @FocusState private var searchHasFocus: Bool
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if geometry.size.width < Tokens.Calendar.compactWidth {
                    calendarPane(compact: true)
                } else {
                    HSplitView {
                        sidebar.frame(minWidth: Tokens.Layout.sidebarWidth,
                                      idealWidth: Tokens.Calendar.sidebarWidth, maxWidth: Tokens.Layout.sidebarMaxWidth)
                        calendarPane(compact: false).frame(minWidth: Tokens.Calendar.contentMinWidth)
                    }
                }
                footer
            }
        }
        .background(Tokens.Surface.primary)
        .background { undoShortcutMonitor }
        .environment(\.timeZone, model.calendar.timeZone)
        .task(id: "\(model.mode.rawValue)-\(model.date.timeIntervalSince1970)") { if isActive { await model.refresh() } }
        .task(id: searchRequest) {
            guard isActive else { return }
            await model.searchEvents()
        }
        .sheet(item: $model.editor) { draft in
            CalendarEventEditor(draft: draft, calendars: model.calendars, calendar: model.calendar,
                                knownExceptionCount: model.editor?.followingExceptionsCount,
                                additionalRecipients: model.editor?.additionalNotificationRecipients ?? []) { edited in
                try await model.save(edited)
            }
        }
        .sheet(isPresented: $showActivity) { CalendarActivityView(model: model) }
        .sheet(isPresented: $showManagement) { CalendarManagementView(model: model) }
        .sheet(isPresented: $showImportReview) {
            CalendarImportReview(events: importEvents, calendars: model.calendars) { events, calendarKey in
                for item in events {
                    try await model.save(CalendarEditorDraft(event: item.event, calendarKey: calendarKey, isImport: true, importedExceptions: item.exceptions))
                }
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                importEvents = try CalendarImportExport.read(url)
                showImportReview = true
            } catch { model.errorMessage = error.localizedDescription }
        }
        .confirmationDialog("Delete event?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { event in
            Button("Delete this event", role: .destructive) { perform { try await model.delete(event, scope: .occurrence) } }
            if event.isRecurring {
                Button("Delete this and following events", role: .destructive) { perform { try await model.delete(event, scope: .following) } }
                Button("Delete all events", role: .destructive) { perform { try await model.delete(event, scope: .series) } }
            }
        } message: { event in
            let recipients = Array(Set((event.event.attendees ?? []).map(\.email))).sorted()
            Text(recipients.isEmpty ? "Delete “\(event.title)”?" : "Delete “\(event.title)”? Google Calendar will notify: \(recipients.joined(separator: ", ")).")
        }
        .confirmationDialog("Undo the last calendar change?", isPresented: Binding(
            get: { model.undoConfirmation != nil },
            set: { if !$0 { model.cancelUndo() } }
        ), presenting: model.undoConfirmation) { _ in
            Button("Undo and notify guests") { Task { await model.confirmUndo() } }
            Button("Cancel", role: .cancel) { model.cancelUndo() }
        } message: { recipients in
            Text("Google Calendar will send an update to: " + recipients.joined(separator: ", ") + ".")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isActive { Task { await model.refresh() } }
        }
        .onExitCommand { if isActive { model.selectedEventID = nil } }
    }

    private func calendarPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            header(compact: compact)
            Divider()
            calendarContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(spacing: Tokens.Space.s2) {
                if compact {
                    Button { showCalendarList.toggle() } label: {
                        Image(systemName: "sidebar.left").frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    }
                    .buttonStyle(.borderless).help("Show calendars").accessibilityLabel("Show calendars")
                    .popover(isPresented: $showCalendarList) {
                        sidebar.frame(width: Tokens.Calendar.sidebarWidth, height: Tokens.Calendar.activityHeight)
                    }
                }
                Button { showDatePicker.toggle() } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Text(periodTitle).font(.title2.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain).help("Go to date").accessibilityLabel("Go to date, \(periodTitle)")
                .popover(isPresented: $showDatePicker) {
                    DatePicker("Go to date", selection: $model.date, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding(Tokens.Space.s4)
                }
                Spacer(minLength: Tokens.Space.s2)
                dateNavigation
                Button { model.beginNew(on: model.date) } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("New event", systemImage: "plus")
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help("New event (⌥⌘N)").accessibilityLabel("New event")
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!isActive || !model.calendars.contains(where: \.canWrite))
                actions
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s4) {
                    viewPicker.frame(width: Tokens.Calendar.viewPickerWidth)
                    Spacer(minLength: 0)
                    searchField.frame(width: Tokens.Layout.sidebarWidth)
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    viewPicker
                    searchField
                }
            }
        }
        .padding(Tokens.Space.s4)
        .background(Tokens.Surface.primary)
    }

    private var periodTitle: String {
        if model.mode == .week, let week = model.calendar.dateInterval(of: .weekOfYear, for: model.date),
           let lastDay = model.calendar.date(byAdding: .day, value: -1, to: week.end) {
            let formatter = DateIntervalFormatter()
            formatter.calendar = model.calendar
            formatter.timeZone = model.calendar.timeZone
            formatter.dateTemplate = "yMMMd"
            return formatter.string(from: week.start, to: lastDay)
        }
        let style: Date.FormatStyle = switch model.mode {
        case .day: .dateTime.year().month(.wide).day()
        case .year: .dateTime.year()
        case .week, .month: .dateTime.month(.wide).year()
        }
        return CalendarLayout.format(model.date, style: style, calendar: model.calendar)
    }

    private var viewPicker: some View {
        Picker("View", selection: $model.mode) {
            ForEach(CalendarDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Calendar view")
    }

    private var dateNavigation: some View {
        HStack(spacing: Tokens.Space.s1) {
            Button { navigate(-1) } label: {
                Image(systemName: "chevron.left").frame(width: Tokens.Space.s6, height: Tokens.Space.s8)
            }
            .help("Previous \(model.mode.title.lowercased())").accessibilityLabel("Previous \(model.mode.title.lowercased())")
            Button("Today") { model.date = .now }
                .keyboardShortcut("t", modifiers: [.command])
                .padding(.horizontal, Tokens.Space.s1)
            Button { navigate(1) } label: {
                Image(systemName: "chevron.right").frame(width: Tokens.Space.s6, height: Tokens.Space.s8)
            }
            .help("Next \(model.mode.title.lowercased())").accessibilityLabel("Next \(model.mode.title.lowercased())")
        }.buttonStyle(.borderless).disabled(!isActive)
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private var searchField: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search events", text: $model.searchText)
                .textFieldStyle(.plain).focused($searchHasFocus)
                .accessibilityLabel("Search calendar events")
                .onExitCommand { model.searchText = ""; searchHasFocus = false }
            if !model.searchText.isEmpty {
                Button { model.searchText = ""; searchHasFocus = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Space.s3).frame(height: Tokens.Control.iconButton)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .strokeBorder(searchHasFocus ? Color.accentColor : Tokens.Surface.border,
                              lineWidth: searchHasFocus ? Tokens.Border.focus : Tokens.Border.hairline)
        }
    }

    private var actions: some View {
        Menu {
                Button("Calendar activity…") { showActivity = true }
                Button("Manage calendars…") { showManagement = true }
                Button("Import calendar…") { showImport = true }
                Button("Export displayed events…") { exportEvents() }
                Menu("Export calendar") {
                    ForEach(model.calendars.filter { $0.entry.canReadDetails }) { calendar in
                        Button("\(calendar.accountName) · \(calendar.title)") {
                            perform { try CalendarImportExport.save(try await model.exportCalendar(calendar)) }
                        }
                    }
                }
                Button("Print…") { CalendarImportExport.printEvents(model.events, title: CalendarLayout.format(model.date, style: .dateTime.month(.wide).year(), calendar: model.calendar)) }
                Divider()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Undo last calendar change") { Task { if isActive { await model.undo() } } }
                    .disabled(!isActive || !model.canUndo)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().help("Calendar actions").accessibilityLabel("Calendar actions")
    }

    private var sidebar: some View {
        CalendarSidebar(model: model, manage: { showManagement = true }, connect: connect)
    }

    @ViewBuilder private var calendarContent: some View {
        if model.calendars.isEmpty, !model.isLoading {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "Your calendars in Tern", systemImage: "calendar", message: "Connect Google Calendar to see your schedule and add events.", fillsSpace: false)
                ForEach(model.accounts) { account in
                    Button("Connect \(account.title)") { connect(account.id) }.buttonStyle(.borderedProminent)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.calendars.isEmpty, !model.calendars.contains(where: \.isVisible) {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No calendars selected", systemImage: "calendar.badge.minus", message: "Choose a calendar in the sidebar to show its events.", fillsSpace: false)
                Button("Show all calendars") {
                    for calendar in model.calendars { model.setVisible(id: calendar.id, visible: true) }
                }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.searchText.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.searchStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.searchText = "" }.buttonStyle(.borderless)
                }.padding(Tokens.Space.s4)
                Divider()
                CalendarSearchResults(events: model.searchResults, calendar: model.calendar, selectedID: $model.selectedEventID, edit: model.edit)
            }
        } else {
            CalendarGridViews(mode: $model.mode, date: $model.date, calendar: model.calendar, events: model.events,
                              selectedID: $model.selectedEventID, newEvent: model.beginNew, newAllDay: beginAllDay, edit: model.edit,
                              move: prepareMove, resize: prepareResize,
                              delete: { deleteTarget = $0 }, duplicate: model.duplicate)
                .focusable().focused($hasKeyboardFocus)
                .onDeleteCommand { if isActive, let selected { deleteTarget = selected } }
                .onCopyCommand { copyProviders() }
                .onPasteCommand(of: [.plainText]) { providers in paste(providers) }
                .onKeyPress(.return) { guard isActive, let selected else { return .ignored }; model.edit(selected); return .handled }
                .onKeyPress(.leftArrow) { guard isActive else { return .ignored }; navigate(-1); return .handled }
                .onKeyPress(.rightArrow) { guard isActive else { return .ignored }; navigate(1); return .handled }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s2) {
            if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing calendars") }
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).lineLimit(2)
                Button("Dismiss") { model.errorMessage = nil }.buttonStyle(.link)
            } else { Text(model.statusText).foregroundStyle(.secondary).lineLimit(1).help(model.statusText) }
            Spacer()
            Text(model.calendar.timeZone.identifier.replacingOccurrences(of: "_", with: " "))
                .foregroundStyle(.secondary).lineLimit(1).help("Calendar time zone")
        }
        .font(.caption).padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.muted)
    }

    private var searchRequest: [String] {
        [model.searchText, String(model.date.timeIntervalSince1970), String(isActive), model.calendar.timeZone.identifier]
            + model.calendars.filter(\.isVisible).map(\.id).sorted()
    }

    private var selected: CalendarDisplayEvent? { (model.events + model.searchResults).first { $0.id == model.selectedEventID } }
    private var undoShortcutMonitor: some View {
        let callback: (() -> Bool)?
        if canHandleCalendarUndo {
            callback = { undoCalendarShortcut() }
        } else {
            callback = nil
        }
        return ShortcutMonitor(isEnabled: false, perform: { _ in false }, commandUndo: callback)
    }
    private var canHandleCalendarUndo: Bool {
        isActive && model.editor == nil && model.undoConfirmation == nil && deleteTarget == nil
            && !showActivity && !showManagement && !showImport && !showImportReview && !showDatePicker && !showCalendarList
    }
    private func undoCalendarShortcut() -> Bool {
        guard canHandleCalendarUndo else { return false }
        // The active Calendar canvas owns Command-Z even with no calendar
        // history, so the hidden mailbox cannot receive the same shortcut.
        if model.canUndo { Task { await model.undo() } }
        return true
    }
    private func navigate(_ amount: Int) {
        model.date = model.calendar.date(byAdding: model.mode.component, value: amount, to: model.date) ?? model.date
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { model.errorMessage = error.localizedDescription } }
    }
    private func connect(_ accountID: String) {
        perform { _ = try await app.enableFeature(.calendar, for: accountID); await model.refresh() }
    }
    private func exportEvents() {
        do { try CalendarImportExport.save(model.events.map { CalendarImportExport.standaloneOccurrence($0.event) }) } catch { model.errorMessage = error.localizedDescription }
    }
    private func beginAllDay(_ date: Date) {
        model.beginNew(on: date)
        let start = model.calendar.startOfDay(for: date)
        let end = model.calendar.date(byAdding: .day, value: 1, to: start) ?? start
        model.editor?.event.start = CalendarDateTime(date: start, timeZone: model.calendar.timeZone, allDay: true)
        model.editor?.event.end = CalendarDateTime(date: end, timeZone: model.calendar.timeZone, allDay: true)
    }
    private func prepareMove(_ event: CalendarDisplayEvent, to date: Date) {
        guard event.isRecurring || !(event.event.attendees ?? []).isEmpty else {
            perform { try await model.move(event, to: date) }; return
        }
        var changed = event.event
        let zone = TimeZone(identifier: changed.start?.timeZone ?? "") ?? model.calendar.timeZone
        let end: Date
        if event.isAllDay {
            let days = max(1, model.calendar.dateComponents([.day], from: event.start, to: event.end).day ?? 1)
            end = model.calendar.date(byAdding: .day, value: days, to: date) ?? date
        } else { end = date.addingTimeInterval(event.end.timeIntervalSince(event.start)) }
        changed.start = CalendarDateTime(date: date, timeZone: zone, allDay: event.isAllDay)
        changed.end = CalendarDateTime(date: end, timeZone: zone, allDay: event.isAllDay)
        model.edit(event, proposedEvent: changed)
    }
    private func prepareResize(_ event: CalendarDisplayEvent, end: Date) {
        guard event.isRecurring || !(event.event.attendees ?? []).isEmpty else {
            perform { try await model.resize(event, end: end) }; return
        }
        var changed = event.event
        changed.end = CalendarDateTime(date: end, timeZone: model.calendar.timeZone, allDay: event.isAllDay)
        model.edit(event, proposedEvent: changed)
    }
    private func copyProviders() -> [NSItemProvider] {
        guard isActive, let selected else { return [] }
        do { return [NSItemProvider(object: try CalendarImportExport.clipboardString(for: selected.event) as NSString)] }
        catch { model.errorMessage = error.localizedDescription; return [] }
    }
    private func paste(_ providers: [NSItemProvider]) {
        guard isActive, let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            Task { @MainActor in
                do { importEvents = try CalendarImportExport.parse(Data(text.utf8)); showImportReview = true }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
    }
}
