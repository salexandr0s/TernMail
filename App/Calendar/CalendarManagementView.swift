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
    @State private var removingShare: CalendarShare?
    @State private var showAddCalendar = false
    @State private var selectedTab: SettingsTab = .calendars
    private var selected: CalendarDisplayCalendar? { model.calendars.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Picker("Calendar settings section", selection: $selectedTab) {
                Text("Calendars").tag(SettingsTab.calendars)
                Text("Assistant & Scheduling").tag(SettingsTab.scheduling)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
            if let error { CalendarInlineError(message: error) }
            switch selectedTab {
            case .calendars: calendarsTab
            case .scheduling: assistantTab
            }
            if isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Updating calendar settings")
            }
        }
        .disabled(isBusy)
        .onAppear {
            selectedID = model.calendars.first?.id
            accountID = model.accounts.first?.id ?? ""
            showAddCalendar = model.calendars.isEmpty
        }
        .task(id: selectedID) { await loadSelected() }
        .ternConfirm(selected?.entry.isOwner == true ? "Delete this calendar?" : "Remove this calendar?",
                     isPresented: $removingCalendar,
                     actionTitle: selected?.entry.isOwner == true ? "Delete Calendar and Its Events" : "Remove from My Calendars",
                     message: selected?.entry.isOwner == true
                        ? "This permanently deletes the calendar and its events for everyone who uses it."
                        : "The calendar remains available to its owner.") {
            guard let selected else { return }
            perform { try await model.removeCalendar(selected); selectedID = model.calendars.first?.id }
        }
        .ternConfirm("Remove access for \(removingShare.map(Self.shareName) ?? "")?", item: $removingShare,
                     actionTitle: "Remove Access",
                     message: "They lose access to this calendar's events. Google does not notify them.") { share in
            guard let selected else { return }
            perform { try await model.deleteShare(share, calendar: selected); shares = try await model.shares(selected) }
        }
    }

    private var calendarsTab: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if !model.calendars.isEmpty {
                fieldRow("Calendar") {
                    Picker("Calendar", selection: $selectedID) {
                        ForEach(model.calendars) { calendar in
                            Text("\(calendar.title) — \(calendar.accountName)\(calendar.canWrite ? "" : " (read only)")")
                                .tag(Optional(calendar.id))
                        }
                    }
                }
            }
            if let selected {
                calendarSettings(selected)
                Divider()
            }
            DisclosureGroup("Add a Calendar", isExpanded: $showAddCalendar) {
                addCalendars.padding(.top, Tokens.Space.s2)
            }
        }
    }

    @ViewBuilder private func calendarSettings(_ calendar: CalendarDisplayCalendar) -> some View {
        fieldRow("Name") {
            TextField("Calendar name", text: $title)
                .textFieldStyle(.roundedBorder)
                .disabled(!calendar.entry.isOwner || !calendar.canManage)
        }
        fieldRow("Color") {
            HStack(spacing: Tokens.Space.s1) {
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
                    }
                    .buttonStyle(.plain).accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(colorHex.lowercased() == swatch.hex ? .isSelected : [])
                    .help(swatch.name)
                }
            }
        }
        HStack(spacing: Tokens.Space.s2) {
            Button("Save Calendar Settings") {
                perform { try await model.updateCalendar(calendar, title: title, colorHex: colorHex) }
            }
            if calendar.entry.isOwner && !calendar.canManage {
                Button("Enable Calendar Management…") { enable(.calendarManagement, accountID: calendar.accountID) }
            }
        }
        .padding(.leading, fieldLabelWidth + Tokens.Space.s3)

        Divider()
        sectionTitle("Notifications")
        Toggle("Show event notifications on this Mac", isOn: model.notifications(of: calendar))
            .toggleStyle(.checkbox)
        Button("Allow macOS Notifications…") { Task { await model.requestNotifications() } }
            .controlSize(.small)

        Divider()
        sectionTitle("Sharing")
        if calendar.entry.isOwner {
            if calendar.canShare {
                ForEach(shares) { share in shareRow(share, calendar: calendar) }
                fieldRow("Email") {
                    TextField("Email address", text: $shareEmail)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("Access") {
                    HStack(spacing: Tokens.Space.s2) {
                        Picker("Access", selection: $shareRole) {
                            ForEach(["freeBusyReader", "reader", "writer"], id: \.self) { role in Text(Self.roleTitle(role)).tag(role) }
                        }
                        Spacer(minLength: 0)
                        Button("Share Calendar") {
                            let email = shareEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard email.contains("@"), !email.contains(where: \.isWhitespace) else { error = "Enter a complete email address."; return }
                            perform {
                                try await model.saveShare(CalendarShare(id: "", email: email, role: shareRole), calendar: calendar)
                                shareEmail = ""; shares = try await model.shares(calendar)
                            }
                        }
                        .disabled(shareEmail.isEmpty)
                    }
                }
                Text("Google sends a sharing notification to the person you add.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Enable Sharing Controls…") { enable(.calendarSharing, accountID: calendar.accountID) }
            }
        } else {
            Text("Only the calendar owner can change sharing permissions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if calendar.entry.primary != true {
            Divider()
            Button(calendar.entry.isOwner ? "Delete Calendar…" : "Remove Calendar…", role: .destructive) { removingCalendar = true }
                .disabled(calendar.entry.isOwner && !calendar.canManage)
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
                            perform { try await model.saveShare(edited, calendar: calendar); shares = try await model.shares(calendar) }
                        }
                    }
                    Button("Remove Access…", role: .destructive) { removingShare = share }
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
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            fieldRow("Account") {
                Picker("Google account", selection: $accountID) {
                    ForEach(model.accounts) { Text($0.title).tag($0.id) }
                }
            }
            fieldRow("New Calendar") {
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
                    .disabled(accountID.isEmpty || newCalendarTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Create calendar")
                }
            }
            fieldRow("Calendar ID") {
                HStack(spacing: Tokens.Space.s2) {
                    TextField("Google calendar ID", text: $subscriptionID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        perform { try await model.addCalendar(accountID: accountID, id: subscriptionID); subscriptionID = "" }
                    }
                    .disabled(accountID.isEmpty || subscriptionID.isEmpty)
                    .accessibilityLabel("Add existing calendar")
                }
            }
            Text("The calendar must already be shared with this account or be public.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "https://calendar.google.com/calendar/u/0/r/settings/addbyurl") {
                Link("Set up other subscriptions in Google Calendar", destination: url)
                    .font(.caption)
            }
        }
    }

    private var assistantTab: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            sectionTitle("Calendar Access")
            Text("Choose what the assistant may read. Hiding a calendar in the main view does not change this access.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.calendars) { calendar in
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    HStack(spacing: Tokens.Space.s3) {
                        Label {
                            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                                Text(calendar.title).lineLimit(1)
                                Text(calendar.accountName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: { Circle().fill(calendar.color).frame(width: Tokens.Space.s2, height: Tokens.Space.s2) }
                        Spacer(minLength: Tokens.Space.s2)
                        Picker("Assistant access", selection: model.assistantAccess(of: calendar)) {
                            ForEach(CalendarAIAccess.allCases) { access in Text(access.title).tag(access) }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Assistant access to \(calendar.title)")
                    }
                    Toggle("Include when finding available times", isOn: model.scheduling(of: calendar))
                        .toggleStyle(.checkbox)
                }
            }
            Divider()
            sectionTitle("Working Hours")
            HStack(spacing: Tokens.Space.s4) {
                Stepper("From \(hourLabel(model.workingStartHour))", value: $model.workingStartHour, in: 0...23)
                Stepper("Until \(hourLabel(model.workingEndHour))", value: $model.workingEndHour, in: 1...24)
            }
            HStack(spacing: Tokens.Space.s3) {
                ForEach(weekdayOrder, id: \.self) { day in
                    Toggle(model.calendar.shortWeekdaySymbols[day - 1], isOn: $model.workingWeekdays.contains(day))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(model.calendar.weekdaySymbols[day - 1])
                }
            }
            Divider()
            sectionTitle("Display")
            fieldRow("Time Zone") {
                CalendarTimeZonePicker(title: "Time Zone", identifier: $model.timeZoneID)
            }
            fieldRow("Week Starts") {
                Picker("Start week on", selection: $model.firstWeekday) {
                    ForEach(1...7, id: \.self) { day in Text(model.calendar.weekdaySymbols[day - 1]).tag(day) }
                }
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
        formatter.setLocalizedDateFormatFromTemplate("j")
        let date = model.calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now) ?? .now
        return formatter.string(from: date)
    }

    private var fieldLabelWidth: CGFloat { Tokens.Space.s12 * 2 }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            Text(label).frame(width: fieldLabelWidth, alignment: .trailing)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
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
