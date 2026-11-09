import SwiftUI

/// An event's context menu, the same in every calendar view. Share sends the
/// occurrence as an .ics file, as dragging it out does.
struct CalendarEventMenuItems: View {
    @Environment(\.prepareForMeeting) private var prepareForMeeting
    let event: CalendarDisplayEvent
    let edit: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    let delete: (CalendarDisplayEvent) -> Void

    var body: some View {
        Button("Open Event") { edit(event) }
        if let prepareForMeeting {
            Button("Prepare for Meeting", systemImage: "list.bullet.clipboard") { prepareForMeeting(event) }
                .disabled(event.isPending)
        }
        Button("Duplicate") { duplicate(event) }
        ShareLink(item: CalendarEventTransfer(event), preview: SharePreview(event.title)) { Text("Share") }
        Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
    }
}
