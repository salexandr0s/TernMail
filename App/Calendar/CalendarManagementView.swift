import GmailAPI
import SwiftUI

/// The Calendar pane's content: calendars, sharing, assistant access and
/// scheduling. The Settings window supplies the frame and the title.
struct CalendarManagementView: View {
    private enum SettingsTab: Hashable {
        case calendars
        case scheduling
    }

    @Environment(AppModel.self) private var app
    @Environment(SettingsUnsavedChanges.self) private var unsaved
    @AppStorage(SettingsDestination.storageKey) private var settingsDestination = SettingsDestination.calendar.rawValue
    @Bindable var model: CalendarModel
    @State private var selectedID: String?
    @State private var accountID = ""
    @State private var newCalendarTitle = ""
    @State private var subscriptionID = ""
    @State private var draft = CalendarSettingsDraft()
    @State private var shareList = CalendarShareList()
    @State private var shareEmail = ""
    @State private var shareRole = "reader"
    @State private var isBusy = false
    @State private var error: String?
    @State private var removingCalendar = false
    @State private var removingShare: PendingShareRemoval?
    @State private var showAddCalendar = false
    @State private var selectedTab: SettingsTab = .calendars
    @State private var pendingCalendarID: String?
    private var selected: CalendarDisplayCalendar? { model.calendars.first { $0.id == selectedID } }

    /// A person picked for removal, with the calendar they were listed under.
    private struct PendingShareRemoval {
        var share: CalendarShare
        var calendar: CalendarDisplayCalendar
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Calendar settings section", selection: $selectedTab) {
                Text("Calendars").tag(SettingsTab.calendars)
                Text("Assistant & Scheduling").tag(SettingsTab.scheduling)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.top, Tokens.Space.s4)
            .padding(.bottom, Tokens.Space.s2)
            SettingsPage {
                if let error {
                    Section { SettingsErrorLabel(error) }
                }
                switch selectedTab {
                case .calendars: calendarsTab
                case .scheduling: assistantTab
                }
            }
        }
        .disabled(isBusy)
        .overlay(alignment: .topTrailing) {
            if isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Updating calendar settings")
                    .padding(Tokens.Space.s5)
            }
        }
        .onChange(of: model.calendars, initial: true) { _, calendars in
            if !calendars.contains(where: { $0.id == selectedID }) {
                selectedID = calendars.first?.id
                draft = CalendarSettingsDraft(calendar: calendars.first)
                showAddCalendar = calendars.isEmpty
            } else if !draft.hasChanges {
                draft = CalendarSettingsDraft(calendar: selected)
            }
        }
        .onChange(of: model.accounts.map(\.id), initial: true) { _, ids in
            if !ids.contains(accountID) { accountID = ids.first ?? "" }
        }
        .onChange(of: draft.hasChanges, initial: true) { _, changed in
            if changed { unsaved.set("calendar") } else { unsaved.clear() }
        }
        .onDisappear { unsaved.clear() }
        .task(id: selectedID) { await loadSelected() }
        .ternConfirm("Discard changes to this calendar?", item: $pendingCalendarID,
                     actionTitle: "Discard Changes", message: "Your unsaved name and color changes are lost.") { id in
            selectedID = id
        }
        .ternConfirm(selected?.entry.isOwner == true ? "Delete this calendar?" : "Remove this calendar?",
                     isPresented: $removingCalendar,
                     actionTitle: selected?.entry.isOwner == true ? "Delete Calendar and Its Events" : "Remove from My Calendars",
                     message: selected?.entry.isOwner == true
                        ? "This permanently deletes the calendar and its events for everyone who uses it."
                        : "The calendar remains available to its owner.") {
            guard let selected else { return }
            perform { try await model.removeCalendar(selected); selectedID = model.calendars.first?.id }
        }
        .ternConfirm("Remove access for \(removingShare.map { Self.shareName($0.share) } ?? "")?", item: $removingShare,
                     actionTitle: "Remove Access",
                     message: "They lose access to this calendar's events. Google does not notify them.") { removal in
            // The calendar the person was listed under, even if the selection changed since.
            perform {
                try await model.deleteShare(removal.share, calendar: removal.calendar)
                try await shareList.reload(removal.calendar, using: model.shares)
            }
        }
    }

    @ViewBuilder private var calendarsTab: some View {
        if !model.calendars.isEmpty {
            Section {
                SettingsControlRow("Calendar") {
                    Picker("Calendar", selection: calendarSelection) {
                        ForEach(model.calendars) { calendar in
                            Text("\(calendar.title) (\(calendar.accountName))")
                                .tag(Optional(calendar.id))
                        }
                    }
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                    .help(selected.map { "\($0.title) (\($0.accountName))" } ?? "Calendar")
                }
                if let selected { calendarIdentity(selected) }
            }
        } else {
            Section {
                SettingsNote("Add an account and enable Calendar in Connections to see its calendars.", systemImage: "calendar.badge.plus")
                Button("Open Connections") { settingsDestination = SettingsDestination.connections.rawValue }
                    .buttonStyle(.link)
            }
        }
        if let selected { calendarSettings(selected) }
        if !model.accounts.isEmpty {
            Section {
                DisclosureGroup("Add a Calendar", isExpanded: $showAddCalendar) {
                    addCalendars
                }
            }
        }
    }

    @ViewBuilder private func calendarSettings(_ calendar: CalendarDisplayCalendar) -> some View {
        Section {
            TextField("Name", text: $draft.title)
                .disabled(!calendar.entry.isOwner || !calendar.canManage)
            if calendar.entry.isOwner && !calendar.canManage {
                SettingsControlRow("Rename this calendar", detail: "Requires Calendar Management access.") {
                    Button("Enable…") { enable(.calendarManagement, accountID: calendar.accountID) }
                        .accessibilityLabel("Enable Calendar Management")
                }
            } else if !calendar.entry.isOwner {
                SettingsNote("Only the owner can rename this calendar.", systemImage: "lock")
            }
            SettingsControlRow("Color") { colorPicker }
            HStack(spacing: Tokens.Space.s3) {
                if draft.hasChanges {
                    Text("Unsaved changes").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Revert") { draft = CalendarSettingsDraft(calendar: calendar) }
                    .disabled(!draft.hasChanges)
                Button("Save Changes") { saveCalendar() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasChanges || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Name and Color")
        } footer: {
            Text("The name is shared with everyone. The color changes only for your account.")
        }

        Section("Notifications") {
            SettingsToggleRow("Event Notifications", detail: "Show this calendar's reminders on this Mac.", isOn: model.notifications(of: calendar))
            Button("Allow macOS Notifications…") {
                Task { await model.requestNotifications() }
            }
            .buttonStyle(.link)
        }

        sharingSection(calendar)
        if calendar.entry.primary != true {
            Section {
                Button(calendar.entry.isOwner ? "Delete Calendar…" : "Remove Calendar…", role: .destructive) { removingCalendar = true }
                    .disabled(calendar.entry.isOwner && !calendar.canManage)
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: Tokens.Space.s1) {
            ForEach(colorChoices, id: \.hex) { swatch in
                Button { draft.colorHex = swatch.hex } label: {
                    Circle().fill(Color(calendarHex: swatch.hex))
                        .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                        .overlay {
                            if draft.colorHex.lowercased() == swatch.hex {
                                Circle().stroke(.primary, lineWidth: Tokens.Border.focus)
                                    .padding(-Tokens.Space.s0_5)
                            }
                        }
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(draft.colorHex.lowercased() == swatch.hex ? .isSelected : [])
                .help(swatch.name)
            }
        }
    }

    private var colorChoices: [(hex: String, name: String)] {
        guard let original = draft.calendar?.colorHex.lowercased(),
              !Self.calendarColors.contains(where: { $0.hex == original }) else { return Self.calendarColors }
        return [(original, "Current color")] + Self.calendarColors
    }

    private func sharingSection(_ calendar: CalendarDisplayCalendar) -> some View {
        Section("Sharing") {
            if calendar.entry.isOwner {
                if calendar.canShare {
                    ForEach(shareList.shares(for: calendar)) { share in shareRow(share, calendar: calendar) }
                    TextField("Email", text: $shareEmail, prompt: Text("Email address"))
                    Picker("Access", selection: $shareRole) {
                        ForEach(["freeBusyReader", "reader", "writer"], id: \.self) { role in Text(Self.roleTitle(role)).tag(role) }
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button("Share Calendar") {
                            let email = shareEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard email.contains("@"), !email.contains(where: \.isWhitespace) else { error = "Enter a complete email address."; return }
                            perform {
                                try await model.saveShare(CalendarShare(id: "", email: email, role: shareRole), calendar: calendar)
                                shareEmail = ""; try await shareList.reload(calendar, using: model.shares)
                            }
                        }
                        .disabled(shareEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    SettingsNote("Google sends a sharing notification to the person you add.")
                } else {
                    SettingsControlRow("Sharing Controls", detail: "Manage who can see or edit this calendar.") {
                        Button("Enable…") { enable(.calendarSharing, accountID: calendar.accountID) }
                            .accessibilityLabel("Enable Sharing Controls")
                    }
                }
            } else {
                SettingsNote("Only the calendar owner can change sharing permissions.", systemImage: "lock")
            }
        }
    }

    private func shareRow(_ share: CalendarShare, calendar: CalendarDisplayCalendar) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text(Self.shareName(share))
                    .lineLimit(1).truncationMode(.middle)
                    .help(Self.shareName(share))
                Text(Self.roleTitle(share.role)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.Space.s2)
            if share.role != "owner" {
                Menu {
                    ForEach(["freeBusyReader", "reader", "writer"], id: \.self) { role in
                        Button(Self.roleTitle(role)) {
                            var edited = share; edited.role = role
                            perform {
                                try await model.saveShare(edited, calendar: calendar)
                                try await shareList.reload(calendar, using: model.shares)
                            }
                        }
                    }
                    Button("Remove Access…", role: .destructive) {
                        removingShare = PendingShareRemoval(share: share, calendar: calendar)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Sharing options for \(Self.shareName(share))")
            }
        }
    }

    private static func shareName(_ share: CalendarShare) -> String {
        share.email.isEmpty ? "Everyone" : share.email
    }

    private static let calendarColors: [(hex: String, name: String)] = [
        ("#4285f4", "Blue"), ("#d50000", "Red"), ("#f4511e", "Orange"), ("#f6bf26", "Yellow"),
        ("#0b8043", "Green"), ("#039be5", "Sky blue"), ("#8e24aa", "Purple"), ("#616161", "Gray")
    ]

    private var addCalendars: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Account", selection: $accountID) {
                ForEach(model.accounts) { Text($0.title).tag($0.id) }
            }
            SettingsControlRow("New Calendar") {
                HStack(spacing: Tokens.Space.s2) {
                    TextField("New calendar name", text: $newCalendarTitle)
                        .textFieldStyle(.roundedBorder)
                    Button("Create") {
                        perform {
                            if model.accounts.first(where: { $0.id == accountID })?.canManage != true { _ = try await app.enableFeature(.calendarManagement, for: accountID) }
                            try await model.createCalendar(accountID: accountID, title: newCalendarTitle)
                            newCalendarTitle = ""
                        }
                    }
                    .disabled(accountID.isEmpty || newCalendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Create calendar")
                }
            }
            SettingsControlRow("Calendar ID") {
                HStack(spacing: Tokens.Space.s2) {
                    TextField("Google calendar ID", text: $subscriptionID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        perform { try await model.addCalendar(accountID: accountID, id: subscriptionID); subscriptionID = "" }
                    }
                    .disabled(accountID.isEmpty || subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add existing calendar")
                }
            }
            SettingsNote("The calendar must already be shared with this account or be public.")
            if let url = URL(string: "https://calendar.google.com/calendar/u/0/r/settings/addbyurl") {
                Link("Set up other subscriptions in Google Calendar", destination: url)
                    .font(.caption)
            }
        }
        .padding(.vertical, Tokens.Space.s2)
    }

    @ViewBuilder private var assistantTab: some View {
        Section("Calendar Access") {
            SettingsNote("Choose what the assistant may read. Hiding a calendar in the main view does not change this access.")
            if model.calendars.isEmpty {
                Text("No calendars connected").foregroundStyle(.secondary)
            }
        }
        ForEach(model.calendars) { calendar in
            Section {
                calendarIdentity(calendar)
                Picker("Assistant Access", selection: model.assistantAccess(of: calendar)) {
                    ForEach(CalendarAIAccess.allCases) { access in Text(access.title).tag(access) }
                }
                .accessibilityLabel("Assistant access to \(calendar.title)")
                SettingsToggleRow("Include in Scheduling", detail: "Use this calendar when finding available times.",
                                  isOn: model.scheduling(of: calendar))
                    .accessibilityLabel("Include \(calendar.title) in scheduling")
            }
        }
        Section("Working Hours") {
            Picker("Start", selection: $model.workingStartHour) {
                ForEach(0...23, id: \.self) { Text(hourLabel($0)).tag($0) }
            }
            Picker("End", selection: $model.workingEndHour) {
                ForEach(1...24, id: \.self) { Text(hourLabel($0)).tag($0) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Space.s16))], alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(weekdayOrder, id: \.self) { day in
                    Toggle(model.calendar.shortWeekdaySymbols[day - 1], isOn: $model.workingWeekdays.contains(day))
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(model.calendar.weekdaySymbols[day - 1])
                }
            }
            .padding(.vertical, Tokens.Space.s1)
            if model.workingWeekdays.isEmpty {
                SettingsNote("Select at least one day for the assistant to suggest meeting times.")
            }
        }
        Section("Display") {
            CalendarTimeZonePicker(title: "Time Zone", identifier: $model.timeZoneID)
            Picker("Week Starts", selection: $model.firstWeekday) {
                ForEach(1...7, id: \.self) { day in Text(model.calendar.weekdaySymbols[day - 1]).tag(day) }
            }
        }
    }

    /// Weekdays in the user's order, starting from the calendar's first weekday.
    private var weekdayOrder: [Int] {
        let first = model.calendar.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// A whole hour the way the user's locale writes clock times; 24 reads as midnight.
    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = model.calendar
        formatter.timeZone = model.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        let date = model.calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now) ?? .now
        return formatter.string(from: date)
    }

    private func calendarIdentity(_ calendar: CalendarDisplayCalendar) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(calendar.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(calendar.title).font(.body.weight(.medium))
                    .lineLimit(2).help(calendar.title)
                Text(calendar.accountName).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(calendar.accountName)
            }
            Spacer(minLength: Tokens.Space.s2)
            Text(calendar.entry.isOwner ? "Owner" : calendar.canWrite ? "Can edit" : "Read only")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var calendarSelection: Binding<String?> {
        Binding(get: { selectedID }, set: { id in
            guard let id, id != selectedID else { return }
            if draft.hasChanges { pendingCalendarID = id }
            else { selectedID = id }
        })
    }

    private func saveCalendar() {
        let edited = draft
        guard let calendar = edited.calendar else { return }
        perform {
            try await model.updateCalendar(calendar, title: edited.title, colorHex: edited.colorHex)
            draft = CalendarSettingsDraft(calendar: selected)
        }
    }

    private func loadSelected() async {
        shareList.select(selected?.id)
        if draft.calendar?.id != selectedID { draft = CalendarSettingsDraft(calendar: selected) }
        error = nil
        shareEmail = ""
        guard let selected else { return }
        if selected.canShare && selected.entry.isOwner {
            do { try await shareList.reload(selected, using: model.shares) } catch { self.error = error.localizedDescription }
        }
    }
    private func enable(_ feature: AccountFeature, accountID: String) {
        perform {
            _ = try await app.enableFeature(feature, for: accountID)
            await model.refresh()
            await loadSelected()
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        isBusy = true; error = nil
        Task { @MainActor in
            defer { isBusy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
    private static func roleTitle(_ role: String) -> String {
        switch role {
        case "freeBusyReader": "See availability only"
        case "reader": "See event details"
        case "writer": "Make changes to events"
        case "owner": "Owner"
        default: role
        }
    }
}

/// The original resource is kept until Save, so edits retain Google's conflict checks.
struct CalendarSettingsDraft {
    let calendar: CalendarDisplayCalendar?
    var title: String
    var colorHex: String

    init(calendar: CalendarDisplayCalendar? = nil) {
        self.calendar = calendar
        // A personal display alias must never become an implicit shared rename.
        title = calendar.map { $0.entry.summary ?? $0.entry.id } ?? ""
        colorHex = calendar?.colorHex ?? "#4285f4"
    }

    var hasChanges: Bool {
        guard let calendar else { return false }
        return title != (calendar.entry.summary ?? calendar.entry.id)
            || colorHex.lowercased() != calendar.colorHex.lowercased()
    }
}
