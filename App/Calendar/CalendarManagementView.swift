import GmailAPI
import SwiftUI

struct CalendarManagementView: View {
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
    private var selected: CalendarDisplayCalendar? { model.calendars.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Calendar settings").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                .padding(Tokens.Space.s5)
            Divider()
            TabView {
                calendarsTab.tabItem { Text("Calendars") }
                assistantTab.tabItem { Text("Assistant & scheduling") }
            }.padding(Tokens.Space.s3)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(Tokens.Space.s3) }
            if isBusy { ProgressView().controlSize(.small).padding(Tokens.Space.s2) }
        }
        .frame(width: 720, height: 680)
        .onAppear { selectedID = model.calendars.first?.id; accountID = model.accounts.first?.id ?? "" }
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
                            Label { Text(calendar.title) } icon: { Circle().fill(calendar.color).frame(width: 9, height: 9) }.tag(calendar.id)
                        }
                    }
                }
            }.frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                    if let selected { calendarSettings(selected) }
                    Divider()
                    addCalendars
                }.padding(Tokens.Space.s4)
            }
        }
    }

    @ViewBuilder private func calendarSettings(_ calendar: CalendarDisplayCalendar) -> some View {
        Text(calendar.title).font(.headline)
        Text(calendar.accountName).font(.caption).foregroundStyle(.secondary)
        TextField("Calendar name", text: $title).disabled(!calendar.entry.isOwner || !calendar.canManage)
        HStack {
            Text("Color")
            ForEach(["#4285f4", "#d50000", "#f4511e", "#f6bf26", "#0b8043", "#039be5", "#8e24aa", "#616161"], id: \.self) { hex in
                Button { colorHex = hex } label: {
                    Circle().fill(Color(calendarHex: hex)).frame(width: 20, height: 20)
                        .overlay { if colorHex.lowercased() == hex { Circle().stroke(.primary, lineWidth: 2).padding(-3) } }
                }.buttonStyle(.plain).accessibilityLabel("Calendar color \(hex)")
            }
        }
        Button("Save calendar settings") { perform { try await model.updateCalendar(calendar, title: title, colorHex: colorHex) } }.disabled(isBusy)
        if calendar.entry.isOwner && !calendar.canManage {
            Button("Enable calendar management…") { enable(.calendarManagement, accountID: calendar.accountID) }
        }
        Toggle("Show event notifications on this Mac", isOn: Binding(get: { calendar.notificationsEnabled }, set: { model.setNotifications(id: calendar.id, enabled: $0) }))
        Button("Allow macOS notifications…") { Task { await model.requestNotifications() } }
        if calendar.entry.primary != true {
            Button(calendar.entry.isOwner ? "Delete calendar…" : "Remove calendar…", role: .destructive) { removingCalendar = true }
                .disabled(isBusy || calendar.entry.isOwner && !calendar.canManage)
        }
        Divider()
        Text("Sharing").font(.headline)
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

    private var addCalendars: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Add a calendar").font(.headline)
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
                        Text("\(calendar.accountName) · \(calendar.title)").font(.headline)
                        Picker("Assistant access", selection: Binding(get: { calendar.aiAccess }, set: { model.setAssistantAccess(id: calendar.id, access: $0) })) {
                            ForEach(CalendarAIAccess.allCases) { access in Text(access.title).tag(access) }
                        }
                        Toggle("Include when finding available times", isOn: Binding(get: { calendar.useForScheduling }, set: { model.setScheduling(id: calendar.id, included: $0) }))
                    }
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
