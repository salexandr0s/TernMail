import Foundation
import GmailAPI

/// An alert row in the event editor. Two alerts can hold the same method and
/// time, so each row carries its own identity.
struct EditableReminder: Identifiable {
    let id = UUID()
    var reminder: CalendarReminder
}
