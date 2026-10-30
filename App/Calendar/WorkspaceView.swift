import AppKit
import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case mail, calendar
    var id: String { rawValue }
    var title: String { self == .mail ? "Mail" : "Calendar" }
}

/// Keeping both views mounted preserves native selection and scroll positions.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var showsCalendarAssistant = false
    let mailbox: MailboxModel

    var body: some View {
        @Bindable var app = app
        ZStack {
            MainView(mailbox: mailbox, isActive: app.destination == .mail)
                .opacity(app.destination == .mail ? 1 : 0)
                .allowsHitTesting(app.destination == .mail)
                .accessibilityHidden(app.destination != .mail)
            HStack(spacing: 0) {
                CalendarView(model: app.calendar, isActive: app.destination == .calendar)
                if showsCalendarAssistant {
                    Divider()
                    AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                        onExpand: { openAssistant(fullScreen: true) },
                        onDetach: { openAssistant(fullScreen: false) },
                        onClose: { showsCalendarAssistant = false })
                        .frame(width: Tokens.Assistant.sidebarWidth)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !showsCalendarAssistant {
                    AssistantLauncher(isPresented: false, onToggle: { showsCalendarAssistant = true })
                        .padding(Tokens.Space.s4)
                }
            }
            .opacity(app.destination == .calendar ? 1 : 0)
            .allowsHitTesting(app.destination == .calendar)
            .accessibilityHidden(app.destination != .calendar)
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(app.destination == .calendar ? "Calendar"
            : mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID ? "Attachments" : mailbox.selectedLabelTitle)
        .navigationSubtitle(app.destination == .calendar || mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID
            ? "" : mailbox.selectedMailboxSubtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Destination", selection: $app.destination) {
                    ForEach(WorkspaceDestination.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
        .task { await app.calendar.start() }
        .onChange(of: app.destination, initial: true) { _, destination in
            app.calendar.isVisible = destination == .calendar
        }
        .onChange(of: mailbox.accounts.map(\.account.id)) { _, _ in
            Task { await app.calendar.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await app.calendar.refresh() }
        }
    }

    private func openAssistant(fullScreen: Bool) {
        showsCalendarAssistant = false
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
    }
}
