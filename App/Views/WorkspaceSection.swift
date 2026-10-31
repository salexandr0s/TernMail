import Foundation

/// What the main window shows. The toolbar's picker and the Go menu switch it.
enum WorkspaceSection: String, CaseIterable, Identifiable {
    case mail, calendar, attachments
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .mail: "envelope"
        case .calendar: "calendar"
        case .attachments: "paperclip"
        }
    }
}
