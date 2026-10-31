import AppKit
import MessageContent
import SwiftUI
import UniformTypeIdentifiers

struct CalendarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: CalendarModel
    var isActive = true
    @State private var showActivity = false
    @State private var showImport = false
    @State private var importEvents: [CalendarImportItem] = []
    @State private var showImportReview = false
    /// Repeating events ask for a scope; events with guests ask before notifying them.
    @State private var recurringDeleteTarget: CalendarDisplayEvent?
    @State private var guestDeleteTarget: CalendarDisplayEvent?
    @State private var showDatePicker = false
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @AppStorage(CalendarDisplayMode.storageKey, store: CalendarDefaults.store) private var storedMode = CalendarDisplayMode.week
    @State private var showCalendarList = false
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
        .environment(\.timeZone, model.calendar.timeZone)
        .onAppear { model.mode = storedMode }
        .onChange(of: model.mode) { _, mode in storedMode = mode }
        .task(id: undoManager.map(ObjectIdentifier.init)) { model.undoManager = undoManager }
        .task(id: rangeRequest) { if isActive { await model.reloadOccurrences() } }
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
        .confirmationDialog("Delete this repeating event?", isPresented: $recurringDeleteTarget.isPresent(),
                            titleVisibility: .visible, presenting: recurringDeleteTarget) { event in
            Button("Delete This Event", role: .destructive) { perform { try await model.delete(event, scope: .occurrence) } }
            Button("Delete This and Following Events", role: .destructive) { perform { try await model.delete(event, scope: .following) } }
            Button("Delete All Events", role: .destructive) { perform { try await model.delete(event, scope: .series) } }
        } message: { event in
            Text(deleteMessage(for: event))
        }
        .ternConfirm("Delete “\(guestDeleteTarget?.title ?? "")”?", item: $guestDeleteTarget,
                     actionTitle: "Delete and Notify Guests", message: guestDeleteTarget.map(deleteMessage) ?? "") { event in
            perform { try await model.delete(event, scope: .occurrence) }
        }
        .confirmationDialog("Undo the last calendar change?", isPresented: $model.undoConfirmation.isPresent(),
                            presenting: model.undoConfirmation) { _ in
            Button("Undo and Notify Guests") { Task { await model.confirmUndo() } }
            Button("Cancel", role: .cancel) { model.cancelUndo() }
        } message: { recipients in
            Text("Google Calendar will send an update to: " + recipients.joined(separator: ", ") + ".")
        }
        .onExitCommand { if isActive { model.selectedEventID = nil } }
        .focusedSceneValue(\.calendarModel, isActive ? model : nil)
        .focusedSceneValue(\.calendarActions, isActive ? calendarActions : nil)
    }

    /// What the Calendar, File and Edit menus can open while this view is active.
    private var calendarActions: CalendarActions {
        CalendarActions(
            showActivity: { showActivity = true },
            showManagement: { manageCalendars() },
            importEvents: { showImport = true },
            exportEvents: { exportEvents() },
            exportCalendar: { exportCalendar($0) },
            goToDate: { showDatePicker = true },
            find: { model.searchFocusRequest += 1 },
            print: { printEvents() }
        )
    }

    /// Calendar settings live in the Settings window; this lands on its pane.
    private func manageCalendars() {
        UserDefaults.standard.set("calendar", forKey: SettingsDestination.storageKey)
        openSettings()
    }

    private func printEvents() {
        CalendarImportExport.printEvents(model.events, title: CalendarLayout.format(model.date, style: .dateTime.month(.wide).year(), calendar: model.calendar),
                                         in: NSApp.keyWindow)
    }

    private func calendarPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            header(compact: compact)
            Divider()
            calendarContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The period title above the grid, as Apple Calendar shows it. Navigation
    /// and the view switcher sit in the window toolbar.
    private func header(compact: Bool) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            if compact {
                Button { showCalendarList.toggle() } label: {
                    Image(systemName: "sidebar.left").frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                }
                .buttonStyle(.borderless).help("Show calendars").accessibilityLabel("Show calendars")
                .popover(isPresented: $showCalendarList) {
                    sidebar.frame(width: Tokens.Calendar.sidebarWidth, height: CalendarSidebar.popoverHeight(for: model))
                }
            }
            Button { showDatePicker.toggle() } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Text(periodTitle).font(.title2.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain).help("Go to Date (\(ShortcutCatalog.goToDate.label))").accessibilityLabel("Go to date, \(periodTitle)")
            .popover(isPresented: $showDatePicker) {
                DatePicker("Go to date", selection: $model.date, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding(Tokens.Space.s4)
            }
            Spacer(minLength: Tokens.Space.s2)
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
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
        case .week, .month, .schedule: .dateTime.month(.wide).year()
        }
        return CalendarLayout.format(model.date, style: style, calendar: model.calendar)
    }

    private var sidebar: some View {
        CalendarSidebar(model: model, manage: manageCalendars, connect: connect)
    }

    @ViewBuilder private var calendarContent: some View {
        if model.calendars.isEmpty, !model.isLoading {
            emptyCalendars
        } else if !model.calendars.isEmpty, !model.calendars.contains(where: \.isVisible) {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No calendars selected", systemImage: "calendar.badge.minus", message: "Choose a calendar in the sidebar to show its events.", fillsSpace: false)
                Button("Show All Calendars") {
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
                CalendarSearchResults(events: model.searchResults, calendar: model.calendar, selectedID: $model.selectedEventID,
                                      edit: model.edit, delete: requestDelete, duplicate: model.duplicate)
            }
        } else {
            CalendarGridViews(mode: $model.mode, date: $model.date, calendar: model.calendar, events: model.events,
                              selectedID: $model.selectedEventID, create: model.beginNew(in:), edit: model.edit,
                              change: prepareChange, delete: requestDelete, duplicate: model.duplicate, dropMail: dropMail)
                .focusable().focused($hasKeyboardFocus)
                .onDeleteCommand { if isActive, let selected, selected.canEdit { requestDelete(selected) } }
                .onCopyCommand { copyProviders() }
                .onPasteCommand(of: [.plainText]) { providers in paste(providers) }
                .onKeyPress(.return) { guard isActive, let selected else { return .ignored }; model.edit(selected); return .handled }
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                    guard isActive else { return .ignored }
                    let direction = press.key == .leftArrow ? -1 : 1
                    if press.modifiers.contains(.option) { model.shift(periods: direction) } else { model.shift(steps: direction) }
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                    guard isActive else { return .ignored }
                    return model.selectAdjacentEvent(press.key == .upArrow ? -1 : 1) ? .handled : .ignored
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "cdwmyatg/e12345"), phases: .down, action: calendarShortcut)
        }
    }

    private var emptyCalendars: some View {
        let hasConnection = model.accounts.contains { model.connectionState(for: $0.id).isEnabled }
        // A reload can help only accounts that are already connected.
        let canRetry = model.accounts.contains { !model.connectionState(for: $0.id).needsAuthorization }
        return ScrollView {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: hasConnection ? "No calendars to show" : "Your calendars in Tern",
                               systemImage: "calendar",
                               message: hasConnection ? "Check the account status below to load your calendars."
                                : "Connect Google Calendar to see your schedule and add events.", fillsSpace: false)
                // The only place that asks to connect: the sidebar shows just the month until a calendar loads.
                VStack(spacing: 0) {
                    ForEach(model.accounts) { account in
                        if account.id != model.accounts.first?.id { Divider().padding(.horizontal, Tokens.Space.s3) }
                        CalendarConnectionControl(model: model, account: account, connect: connect, showsAccount: true)
                            .padding(Tokens.Space.s3)
                    }
                }
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .ternOutline(radius: Tokens.Radius.md)
                if app.isSigningIn || canRetry || hasConnection {
                    HStack(spacing: Tokens.Space.s3) {
                        if app.isSigningIn {
                            Button("Cancel Sign-In") { app.auth.cancelSignIn() }
                        } else if canRetry {
                            Button("Retry", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                                .disabled(model.isLoading)
                        }
                        if hasConnection { Button("Manage Calendars…", action: manageCalendars) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(Tokens.Space.s4)
            .frame(maxWidth: Tokens.Sheet.smallWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s2) {
            if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing calendars") }
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.Status.warning)
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

    private var rangeRequest: [String] {
        [String(isActive), model.mode.rawValue, String(model.date.timeIntervalSince1970),
         model.calendar.timeZone.identifier, String(model.firstWeekday)]
    }

    private var searchRequest: [String] {
        [model.searchText, String(model.date.timeIntervalSince1970), String(isActive), model.calendar.timeZone.identifier]
            + model.calendars.filter(\.isVisible).map(\.id).sorted()
    }

    private var selected: CalendarDisplayEvent? { (model.events + model.searchResults).first { $0.id == model.selectedEventID } }

    /// Single keys and arrows act only while no sheet or popover owns the keyboard.
    private var canHandleKeys: Bool {
        isActive && model.editor == nil && model.undoConfirmation == nil
            && recurringDeleteTarget == nil && guestDeleteTarget == nil
            && !showActivity && !showImport && !showImportReview && !showDatePicker && !showCalendarList
    }

    // MARK: Deleting

    /// Repeating events choose a scope and events with guests send cancellations,
    /// so both ask first. A plain event goes straight away; Edit ▸ Undo brings it back.
    private func requestDelete(_ event: CalendarDisplayEvent) {
        guard isActive, event.canEdit else { return }
        if event.isRecurring {
            recurringDeleteTarget = event
        } else if !guests(of: event).isEmpty {
            guestDeleteTarget = event
        } else {
            perform {
                try await model.delete(event, scope: .occurrence)
                model.statusText = "Deleted “\(event.title)”. Edit ▸ Undo restores it."
            }
        }
    }

    private func guests(of event: CalendarDisplayEvent) -> [String] {
        Array(Set((event.event.attendees ?? []).map(\.email))).sorted()
    }

    private func deleteMessage(for event: CalendarDisplayEvent) -> String {
        let recipients = guests(of: event)
        if recipients.isEmpty { return "“\(event.title)” is removed from your calendar." }
        return "Google Calendar sends a cancellation to: \(recipients.joined(separator: ", "))."
    }

    // MARK: Actions

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { model.errorMessage = error.localizedDescription } }
    }
    private func connect(_ accountID: String) {
        perform {
            let state = model.connectionState(for: accountID)
            if state.issue == .signInRequired || (state.isEnabled && state.issue == .permissionDenied) {
                await app.signInAgain(to: accountID)
                await model.refresh()
                return
            }
            guard let grant = try await app.enableFeature(.calendar, for: accountID) else { return }
            guard grant.features.contains(.calendar) else {
                model.errorMessage = CalendarConnectionIssue.permissionDenied.message
                model.connectionStates[accountID] = CalendarConnectionState(isEnabled: false, issue: .permissionDenied)
                return
            }
            model.errorMessage = nil
            await model.refresh()
        }
    }
    private func exportEvents() {
        let events = model.events.map { CalendarImportExport.standaloneOccurrence($0.event) }
        perform { try await CalendarImportExport.save(events, in: NSApp.keyWindow) }
    }
    private func exportCalendar(_ owner: CalendarDisplayCalendar) {
        perform { try await CalendarImportExport.save(try await model.exportCalendar(owner), in: NSApp.keyWindow) }
    }
    private func prepareChange(_ event: CalendarDisplayEvent, range: CalendarEventRange) {
        perform { try await model.change(event, to: range) }
    }
    /// A conversation dropped on the grid opens the editor prefilled; nothing is saved yet.
    private func dropMail(_ link: MailLink, in range: CalendarEventRange) {
        guard isActive else { return }
        Task { await model.beginNew(from: link, in: range) }
    }
    /// Single keys follow the same Settings switch as the mail list.
    private func calendarShortcut(_ key: KeyPress) -> KeyPress.Result {
        guard usesSingleKeys, hasKeyboardFocus, canHandleKeys,
              key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        switch key.characters.lowercased() {
        case "c": model.beginNew(on: CalendarLayout.date(at: 9 * 60, on: model.date, calendar: model.calendar))
        case "d", "1": model.mode = .day
        case "w", "2": model.mode = .week
        case "m", "3": model.mode = .month
        case "y", "4": model.mode = .year
        case "a", "5": model.mode = .schedule
        case "t": model.date = .now
        case "g": showDatePicker = true
        case "/": model.searchFocusRequest += 1
        case "e":
            guard let selected else { return .ignored }
            model.edit(selected)
        default: return .ignored
        }
        return .handled
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
