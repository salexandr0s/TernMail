#if DEBUG
import GmailAPI
import MailStore
import MessageContent
import SwiftUI

/// Explicit UI preview with synthetic identities and no mail or calendar service.
struct AvatarAuditFixtures: View {
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = true
    @State private var section = 0
    @State private var to = [EmailAddress(name: "Example Bank", address: "team@harbor.example.invalid")]
    @State private var cc = [EmailAddress(name: "Alex Example", address: "alex@example.invalid")]
    @State private var bcc = [EmailAddress(name: "Personal", address: "someone@example.invalid")]
    @State private var toFocus = false
    @State private var ccFocus = false
    @State private var bccFocus = false
    @State private var selectedSender = "avatar-photo:alex@example.invalid"
    @State private var senderModels = SenderAvatarModels()
    @State private var showsEvent = false

    private static let accounts = [
        AccountRecord(id: "avatar-photo", email: "alex@example.invalid", displayName: "Alex Example", grantedScopes: [], addedAt: .distantPast),
        AccountRecord(id: "avatar-company", email: "sender@studio.example.invalid", displayName: "Company account", grantedScopes: [], addedAt: .distantPast)
    ]
    private var senders: [ComposeSender] { Self.accounts.flatMap { ComposeSender.choices(account: $0, identities: []) } }
    private var context: AddressAvatarContext {
        AddressAvatarContext(profileAccountIDs: Dictionary(uniqueKeysWithValues: Self.accounts.map { ($0.email, $0.id) }), identity: "avatar-preview")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text("Avatar preview").font(.title2.weight(.semibold))
            Toggle("Show company logos", isOn: $showsLogos)
            Picker("Preview", selection: $section) {
                Text("Compose").tag(0)
                Text("Calendar & accounts").tag(1)
            }.pickerStyle(.segmented)
            if section == 0 { compose } else { calendarAndAccounts }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.addressAvatarContext, context)
        .task {
            AccountProfileImages.shared.setAuditImage(SenderAccountLabel.auditImage, for: Self.accounts[0].id)
            refreshSenders()
        }
        .onChange(of: showsLogos) { _, _ in refreshSenders() }
        .onDisappear { senderModels.stop() }
        .sheet(isPresented: $showsEvent) {
            CalendarEventEditor(draft: Self.eventDraft, calendars: [Self.displayCalendar], calendar: .current,
                                saveTitle: "Keep in preview") { _ in showsEvent = false }
                .environment(\.addressAvatarContext, context)
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("From", selection: $selectedSender) {
                ForEach(senders) { sender in
                    SenderAccountLabel(account: sender.account, address: sender.label,
                                       avatarModel: senderModels.models[sender.id]).tag(sender.id)
                }
            }.pickerStyle(.menu)
            recipient("To", addresses: $to, focus: $toFocus)
            recipient("Cc", addresses: $cc, focus: $ccFocus)
            recipient("Bcc", addresses: $bcc, focus: $bccFocus)
            Text("Type bank to show two complete-address suggestions.").font(.caption).foregroundStyle(.secondary)
            Text("To value: \(to.map(\.displayString).joined(separator: ", "))")
                .font(.caption).textSelection(.enabled)
            Button("Reset recipients") {
                to = [.init(name: "Example Bank", address: "team@harbor.example.invalid")]
                cc = [.init(name: "Alex Example", address: "alex@example.invalid")]
                bcc = [.init(name: "Personal", address: "someone@example.invalid")]
            }
        }
    }

    private func recipient(_ title: String, addresses: Binding<[EmailAddress]>, focus: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Text(title).frame(width: Tokens.Space.s10, alignment: .leading)
            RecipientField(label: title, addresses: addresses, requestsFocus: focus, isEditable: true,
                           accountID: Self.accounts[0].id, avatarContext: context) { query in
                let choices = [EmailAddress(name: "Harbor Bank", address: "team@harbor.example.invalid"),
                               EmailAddress(name: "Cedar Bank", address: "bank@cedar.example.invalid")]
                return choices.filter { $0.displayString.localizedCaseInsensitiveContains(query) }
            }
            .frame(minHeight: Tokens.Space.s8)
        }
        .padding(Tokens.Space.s2)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline))
    }

    private var calendarAndAccounts: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            ForEach(Self.accounts) { account in
                HStack(spacing: Tokens.Space.s3) {
                    AddressAvatar(accountID: account.id, address: account.email, name: account.displayName ?? "")
                    Text(account.displayName ?? account.email)
                    Text(account.email).foregroundStyle(.secondary)
                }
            }
            Button("Open calendar guest details") { showsEvent = true }
        }
    }

    private func refreshSenders() { senderModels.configure(senders: senders, context: context, showsLogos: showsLogos) }
    private static var displayCalendar: CalendarDisplayCalendar {
        .init(entry: GoogleCalendarEntry(id: "avatar-calendar", summary: "Avatar preview", accessRole: "owner"),
              accountID: accounts[0].id, accountName: "Sample account")
    }
    private static var eventDraft: CalendarEditorDraft {
        var event = GoogleCalendarEvent(id: "avatar-event", summary: "Synthetic guest preview",
            start: CalendarDateTime(date: Date(timeIntervalSince1970: 1_793_520_000), timeZone: .current),
            end: CalendarDateTime(date: Date(timeIntervalSince1970: 1_793_523_600), timeZone: .current))
        event.attendees = [CalendarAttendee(email: "team@harbor.example.invalid", displayName: "Example Bank", responseStatus: "accepted"),
                           CalendarAttendee(email: accounts[0].email, displayName: "Alex Example", responseStatus: "accepted"),
                           CalendarAttendee(email: "someone@example.invalid", displayName: "Personal", responseStatus: "needsAction")]
        return CalendarEditorDraft(event: event, calendarKey: displayCalendar.id, isImport: true)
    }
}
#endif
