import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var prepareForMeeting: (@MainActor (CalendarDisplayEvent) -> Void)? = nil
}

/// Both event details and context menus open the same occurrence in its own window.
struct MeetingPreparationOpening: ViewModifier {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.environment(\.prepareForMeeting, { event in
            app.prepareForMeeting(event)
            openWindow(id: MeetingPreparationWindow.sceneID)
        })
    }
}

extension AppModel {
    func prepareForMeeting(_ event: CalendarDisplayEvent) {
        meetingPreparation?.stop()
        meetingPreparation = MeetingPreparationModel(app: self, event: event)
    }
}

struct MeetingPreparationWindow: View {
    static let sceneID = "meeting-preparation"
    @Environment(AppModel.self) private var app
    @State private var window: NSWindow?
    @State private var eventCheck: Task<Void, Never>?

    var body: some View {
        Group {
            if let model = app.meetingPreparation {
                MeetingPreparationView(model: model)
                    .id(ObjectIdentifier(model))
            } else {
                TernEmptyState(title: "Prepare for a meeting", systemImage: "calendar.badge.clock",
                    message: "Open an event and choose Prepare for Meeting.")
            }
        }
        .frame(minWidth: Tokens.Calendar.editorWidth, minHeight: Tokens.Calendar.sheetMinHeight)
        .background(WindowReader { window = $0 })
        .onChange(of: app.calendar.accessRevision) { _, _ in app.meetingPreparation?.revalidateAccess() }
        .onChange(of: app.calendar.lifecycleRevision) { _, _ in app.meetingPreparation?.revalidateAccess() }
        .onChange(of: app.calendar.presentationRevision) { _, _ in updateEvent() }
        .onDisappear { eventCheck?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let closing = notification.object as? NSWindow, closing === window else { return }
            eventCheck?.cancel()
            app.meetingPreparation?.stop()
            app.meetingPreparation = nil
        }
    }

    private func updateEvent() {
        eventCheck?.cancel()
        guard let model = app.meetingPreparation else { return }
        model.revalidateAccess()
        // A range change can remove an event from the visible grid without deleting it.
        if let updated = (app.calendar.events + app.calendar.searchResults).first(where: {
            $0.accountID == model.event.accountID && $0.calendarID == model.event.calendarID
                && $0.event.id == model.event.event.id
        }) {
            model.eventChanged(updated)
        }
        // A deleted occurrence can disappear from both visible collections.
        // Check its exact cached identity instead of interpreting a range change.
        guard let store = app.calendar.store else { model.eventUnavailable(); return }
        let event = model.event
        let lifecycle = app.calendar.lifecycleRevision
        eventCheck = Task {
            do {
                let cached = try await store.event(accountID: event.accountID, calendarID: event.calendarID,
                    eventID: event.event.id)
                guard !Task.isCancelled, app.meetingPreparation === model,
                      app.calendar.lifecycleRevision == lifecycle, model.event.event == event.event else { return }
                if let cached, cached.status != "cancelled" {
                    model.eventChanged(event.replacingEvent(cached))
                } else { model.eventUnavailable() }
            } catch {
                guard !Task.isCancelled, app.meetingPreparation === model,
                      app.calendar.lifecycleRevision == lifecycle, model.event.event == event.event else { return }
                model.eventUnavailable()
            }
        }
    }
}
