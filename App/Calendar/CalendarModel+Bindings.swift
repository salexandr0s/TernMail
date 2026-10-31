import SwiftUI

/// Bindings for the per-calendar controls in the sidebar and Manage Calendars.
/// Each write goes through the setter that saves the preference and updates
/// `calendars`, so the control reads the new value on the next render.
extension CalendarModel {
    func visibility(of calendar: CalendarDisplayCalendar) -> Binding<Bool> {
        Binding(get: { calendar.isVisible }, set: { self.setVisible(id: calendar.id, visible: $0) })
    }

    func notifications(of calendar: CalendarDisplayCalendar) -> Binding<Bool> {
        Binding(get: { calendar.notificationsEnabled }, set: { self.setNotifications(id: calendar.id, enabled: $0) })
    }

    func assistantAccess(of calendar: CalendarDisplayCalendar) -> Binding<CalendarAIAccess> {
        Binding(get: { calendar.aiAccess }, set: { self.setAssistantAccess(id: calendar.id, access: $0) })
    }

    func scheduling(of calendar: CalendarDisplayCalendar) -> Binding<Bool> {
        Binding(get: { calendar.useForScheduling }, set: { self.setScheduling(id: calendar.id, included: $0) })
    }
}
