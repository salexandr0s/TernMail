import GmailAPI
import SwiftUI

struct CalendarManagementView: View {
    private enum SettingsTab: Hashable {
        case calendars
        case scheduling
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CalendarModel
    @State private var selectedID: String?
    @State private var accountID = ""
    @State private var newCalendarTitle = ""
    @State private var subscriptionID = ""
    @State private var title = ""
    @State private var colorHex = "#4285f4"
    @State private var shares: [CalendarShare] = []
    @State private var shareEmail = ""
    @State private var shareRole = "reader"
    @State private var isBusy = false
    @State private var error: String?
    @State private var removingCalendar = false
    @State private var showAddCalendar = false
    @State private var selectedTab: SettingsTab = .calendars
    private var selected: CalendarDisplayCalendar? { model.calendars.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            CalendarSheetHeading(title: "Calendar settings", subtitle: "Manage calendars, sharing and scheduling preferences.", systemImage: "slider.horizontal.3")
            Divider()
            Picker("Calendar settings section", selection: $selectedTab) {
                Text("Calendars").tag(SettingsTab.calendars)
                Text("Assistant & scheduling").tag(SettingsTab.scheduling)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.vertical, Tokens.Space.s3)
            Group {
                switch selectedTab {
                case .calendars: calendarsTab
                case .scheduling: assistantTab
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            Divider()
            VStack(spacing: Tokens.Space.s3) {
                if let error { CalendarInlineError(message: error) }
                HStack {
                    if isBusy { ProgressView().controlSize(.small).accessibilityLabel("Updating calendar settings") }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
                }
            }.padding(Tokens.Space.s4).background(Tokens.Surface.muted)
        }
        .frame(width: Tokens.Calendar.settingsWidth, height: CalendarSheetLayout.height(Tokens.Calendar.settingsHeight))
        .onAppear {
            selectedID = model.calendars.first?.id
            accountID = model.accounts.first?.id ?? ""
            showAddCalendar = model.calendars.isEmpty
        }
        .interactiveDismissDisabled(isBusy)
        .task(id: selectedID) { await loadSelected() }
        .confirmationDialog(selected?.entry.isOwner == true ? "Delete this calendar?" : "Remove this calendar?", isPresented: $removingCalendar) {
            if let selected {
                Button(selected.entry.isOwner ? "Delete calendar and its events" : "Remove from my calendars", role: .destructive) {
                    perform { try await model.removeCalendar(selected); selectedID = model.calendars.first?.id }
                }
            }
        } message: {
            Text(selected?.entry.isOwner == true ? "This permanently deletes the calendar and its events for everyone who uses it." : "The calendar remains available to its owner.")
        }
    }

    private var calendarsTab: some View {
        HSplitView {
            List(selection: $selectedID) {
                ForEach(model.accounts) { account in
                    Section(account.title) {
                        ForEach(model.calendars.filter { $0.accountID == account.id }) { calendar in
                            Label {
                                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                    Text(calendar.title).lineLimit(1)
                                    if !calendar.canWrite { Text("Read only").font(.caption).foregroundStyle(.secondary) }
                                }
                            } icon: { Circle().fill(calendar.color).frame(width: Tokens.Space.s2, height: Tokens.Space.s2) }
                                .tag(calendar.id).help(calendar.title)
                                .padding(.vertical, Tokens.Space.s1)
                        }
                    }
                }
            }.listStyle(.sidebar)
                .frame(minWidth: Tokens.Layout.sidebarMinWidth, idealWidth: Tokens.Layout.sidebarWidth, maxWidth: Tokens.Layout.attachmentWidth)
            Form {
                if let selected { calendarSettings(selected) }
                Section {
                    DisclosureGroup("Add a calendar", isExpanded: $showAddCalendar) {
                        addCalendars.padding(.top, Tokens.Space.s3)
                    }
                }
            }.formStyle(.grouped)
                .disabled(isBusy)
        }
    }

    @ViewBuilder private func calendarSettings(_ calendar: CalendarDisplayCalendar) -> some View {
        Section {
            TextField("Calendar name", text: $title).disabled(!calendar.entry.isOwner || !calendar.canManage)
            HStack(spacing: Tokens.Space.s2) {
                Text("Color")
                Spacer(minLength: Tokens.Space.s2)
                ForEach(Self.calendarColors, id: \.hex) { swatch in
                    Button { colorHex = swatch.hex } label: {
                        Circle().fill(Color(calendarHex: swatch.hex))
                            .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                            .overlay {
                                if colorHex.lowercased() == swatch.hex {
                                    Circle().stroke(.primary, lineWidth: Tokens.Border.focus)
                                        .padding(-Tokens.Space.s0_5)
                                }
                            }
                            .padding(Tokens.Space.s1)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(colorHex.lowercased() == swatch.hex ? .isSelected : [])
                        .help(swatch.name)
                }
            }
            Button("Save calendar settings") { perform { try await model.updateCalendar(calendar, title: title, colorHex: colorHex) } }.disabled(isBusy)
            if calendar.entry.isOwner && !calendar.canManage {
                Button("Enable calendar management…") { enable(.calendarManagement, accountID: calendar.accountID) }
            }
        } header: {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(calendar.title)
                Text(calendar.accountName).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Notifications") {
            Toggle("Show event notifications on this Mac", isOn: Binding(get: { calendar.notificationsEnabled }, set: { model.setNotifications(id: calendar.id, enabled: $0) }))
            Button("Allow macOS notifications…") { Task { await model.requestNotifications() } }
        }
        Section("Sharing") {
            if calendar.entry.isOwner {
                if calendar.canShare {
                    ForEach(shares) { share in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(share.email.isEmpty ? "Everyone" : share.email)
                                Text(Self.roleTitle(share.role)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if share.role != "owner" {
                                Menu {
                                    ForEach(["freeBusyReader", "reader", "writer"], id: \.self) { role in
                                        Button(Self.roleTitle(role)) {
                                            var edited = share; edited.role = role
                                            perform { try await model.saveShare(edited, calendar: calendar); shares = try await model.shares(calendar) }
                                        }
                                    }
                                    Button("Remove access", role: .destructive) {
                                        perform { try await model.deleteShare(share, calendar: calendar); shares = try await model.shares(calendar) }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                                    .accessibilityLabel("Sharing options for \(share.email.isEmpty ? "Everyone" : share.email)")
                            }
                        }
                    }
                    TextField("Email address", text: $shareEmail)
                    Picker("Access", selection: $shareRole) {
                        ForEach(["freeBusyReader", "reader", "writer"], id: \.self) { role in Text(Self.roleTitle(role)).tag(role) }
                    }
                    Button("Share calendar") {
                        let email = shareEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard email.contains("@"), !email.contains(where: \.isWhitespace) else { error = "Enter a complete email address."; return }
                        perform {
                            try await model.saveShare(CalendarShare(id: "", email: email, role: shareRole), calendar: calendar)
                            shareEmail = ""; shares = try await model.shares(calendar)
                        }
                    }.disabled(isBusy || shareEmail.isEmpty)
                    Text("Google sends a sharing notification to the person you add.").font(.caption).foregroundStyle(.secondary)
                } else { Button("Enable sharing controls…") { enable(.calendarSharing, accountID: calendar.accountID) } }
            } else { Text("Only the calendar owner can change sharing permissions.").font(.caption).foregroundStyle(.secondary) }
        }
        if calendar.entry.primary != true {
            Section {
                Button(calendar.entry.isOwner ? "Delete calendar…" : "Remove calendar…", role: .destructive) { removingCalendar = true }
                    .disabled(isBusy || calendar.entry.isOwner && !calendar.canManage)
            }
        }
    }

    private static let calendarColors: [(hex: String, name: String)] = [
        ("#4285f4", "Blue"), ("#d50000", "Red"), ("#f4511e", "Orange"), ("#f6bf26", "Yellow"),
        ("#0b8043", "Green"), ("#039be5", "Sky blue"), ("#8e24aa", "Purple"), ("#616161", "Gray")
    ]

    private var addCalendars: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Google account", selection: $accountID) { ForEach(model.accounts) { Text($0.title).tag($0.id) } }
            TextField("New calendar name", text: $newCalendarTitle)
            Button("Create calendar") {
                perform {
                    if model.accounts.first(where: { $0.id == accountID })?.canManage != true { _ = try await app.enableFeature(.calendarManagement, for: accountID) }
                    try await model.createCalendar(accountID: accountID, title: newCalendarTitle)
                    newCalendarTitle = ""
                }
            }.disabled(isBusy || accountID.isEmpty || newCalendarTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            Divider()
            TextField("Google calendar ID", text: $subscriptionID)
            Button("Add existing calendar") {
                perform { try await model.addCalendar(accountID: accountID, id: subscriptionID); subscriptionID = "" }
            }.disabled(isBusy || accountID.isEmpty || subscriptionID.isEmpty)
            Text("The calendar must already be shared with this account or be public.").font(.caption).foregroundStyle(.secondary)
            if let url = URL(string: "https://calendar.google.com/calendar/u/0/r/settings/addbyurl") {
                Link("Set up other subscriptions in Google Calendar", destination: url)
            }
        }
    }

    private var assistantTab: some View {
        Form {
            Section("Calendar access") {
                Text("Choose what the assistant may read. Hiding a calendar in the main view does not change this access.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.calendars) { calendar in
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Label {
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(calendar.title).font(.headline)
                                Text(calendar.accountName).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Circle().fill(calendar.color).frame(width: Tokens.Space.s2, height: Tokens.Space.s2) }
                        Picker("Assistant access", selection: Binding(get: { calendar.aiAccess }, set: { model.setAssistantAccess(id: calendar.id, access: $0) })) {
                            ForEach(CalendarAIAccess.allCases) { access in Text(access.title).tag(access) }
                        }
                        Toggle("Include when finding available times", isOn: Binding(get: { calendar.useForScheduling }, set: { model.setScheduling(id: calendar.id, included: $0) }))
                    }.padding(.vertical, Tokens.Space.s2)
                }
            }
            Section("Working hours") {
                HStack {
                    Stepper("From \(model.workingStartHour):00", value: $model.workingStartHour, in: 0...23)
                    Stepper("Until \(model.workingEndHour):00", value: $model.workingEndHour, in: 1...24)
                }
                HStack {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(get: { model.workingWeekdays.contains(day) }, set: { included in
                            if included { model.workingWeekdays.insert(day) } else { model.workingWeekdays.remove(day) }
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            Section("Display") {
                TextField("Time zone", text: $model.timeZoneID)
                Picker("Start week on", selection: $model.firstWeekday) {
                    ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                }
            }
        }.formStyle(.grouped)
    }

    private func loadSelected() async {
        guard let selected else { return }
        title = selected.title; colorHex = selected.colorHex; shares = []
        if selected.canShare && selected.entry.isOwner {
            do { shares = try await model.shares(selected) } catch { self.error = error.localizedDescription }
        }
    }
    private func enable(_ feature: AccountFeature, accountID: String) {
        perform { _ = try await app.enableFeature(feature, for: accountID); await model.refresh(); await loadSelected() }
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
