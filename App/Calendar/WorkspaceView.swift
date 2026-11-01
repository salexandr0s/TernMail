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
    /// Shared with the mail assistant, so the panel keeps one width across launches.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    let mailbox: MailboxModel

    var body: some View {
        ZStack {
            MainView(mailbox: mailbox, isActive: app.destination == .mail,
                isCalendarAssistantPresented: showsCalendarAssistant,
                onCalendarAssistantToggle: { showsCalendarAssistant.toggle() })
                .opacity(app.destination == .mail ? 1 : 0)
                .allowsHitTesting(app.destination == .mail)
                .accessibilityHidden(app.destination != .mail)
                .background {
                    MailWorkspacePerformance(mailbox: mailbox, isActive: app.destination == .mail)
                }
            HStack(spacing: 0) {
                CalendarView(model: app.calendar, isActive: app.destination == .calendar)
                if showsCalendarAssistant {
                    Rectangle()
                        .fill(Tokens.Surface.border)
                        .frame(width: Tokens.Border.hairline)
                        .overlay {
                            AssistantSidebarResizeHandle(width: CGFloat(preferredAssistantWidth), onResize: resizeAssistant)
                                .frame(width: Tokens.Space.s3)
                                .accessibilityElement()
                                .accessibilityLabel("Assistant width")
                                .accessibilityValue("\(Int(preferredAssistantWidth)) points")
                                .accessibilityAdjustableAction { direction in
                                    resizeAssistant(CGFloat(preferredAssistantWidth) + (direction == .increment ? Tokens.Space.s4 : -Tokens.Space.s4))
                                }
                        }
                    AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                        onExpand: { openAssistant(fullScreen: true) },
                        onDetach: { openAssistant(fullScreen: false) },
                        onClose: { showsCalendarAssistant = false })
                        .frame(width: CGFloat(preferredAssistantWidth))
                }
            }
            .opacity(app.destination == .calendar ? 1 : 0)
            .allowsHitTesting(app.destination == .calendar)
            .accessibilityHidden(app.destination != .calendar)
            .background {
                CalendarWorkspacePerformance(model: app.calendar, isActive: app.destination == .calendar)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(app.destination == .calendar ? "Calendar"
            : mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID ? "Attachments" : mailbox.selectedLabelTitle)
        .navigationSubtitle(app.destination == .calendar || mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID
            ? "" : mailbox.selectedMailboxSubtitle)
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

    private func resizeAssistant(_ width: CGFloat) {
        preferredAssistantWidth = Double(min(max(width, Tokens.Assistant.sidebarMinWidth), Tokens.Assistant.sidebarMaxWidth))
    }

    private func openAssistant(fullScreen: Bool) {
        showsCalendarAssistant = false
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
    }
}

/// Keep diagnostics' observation dependencies outside the expensive workspace
/// body. A new data revision should not re-evaluate both destination trees.
private struct MailWorkspacePerformance: View {
    let mailbox: MailboxModel
    let isActive: Bool

    private var ready: Bool {
        isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID && mailbox.isListPresentationReady
    }

    var body: some View {
        VisibleContentProbe(kinds: [.workspace, .mailbox, .selectionFeedback],
            isActive: ready, revision: mailbox.listPresentationRevision)
        .onChange(of: ready, initial: true) { _, value in
            if value { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained) }
        }
        .onChange(of: mailbox.listPresentationRevision) { _, _ in
            if ready { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .local) }
        }
    }
}

private struct CalendarWorkspacePerformance: View {
    let model: CalendarModel
    let isActive: Bool

    private var ready: Bool { isActive && model.presentation != nil }

    var body: some View {
        VisibleContentProbe(kind: .workspace, isActive: ready, revision: model.presentationRevision)
            .onChange(of: ready, initial: true) { _, value in
                if value { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained) }
            }
            .onChange(of: model.presentationRevision) { _, _ in
                if ready { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .local) }
            }
    }
}
