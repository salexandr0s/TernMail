import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general, accounts, profiles, notifications, reading, messageList, composing
    case signatures, filters, blocked, vacation, attachments, failedChanges, maintenance, assistant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .profiles: "Profiles"
        case .notifications: "Notifications"
        case .reading: "Reading"
        case .messageList: "Message List"
        case .composing: "Composing"
        case .signatures: "Gmail Signatures"
        case .filters: "Filters"
        case .blocked: "Blocked Senders"
        case .vacation: "Vacation Responder"
        case .attachments: "Attachments"
        case .failedChanges: "Failed Changes"
        case .maintenance: "Cache & Storage"
        case .assistant: "Assistant"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .profiles: "person.2"
        case .notifications: "bell"
        case .reading: "doc.text"
        case .messageList: "list.bullet.rectangle"
        case .composing: "square.and.pencil"
        case .signatures: "signature"
        case .filters: "line.3.horizontal.decrease.circle"
        case .blocked: "person.crop.circle.badge.xmark"
        case .vacation: "sun.max"
        case .attachments: "paperclip"
        case .failedChanges: "exclamationmark.arrow.triangle.2.circlepath"
        case .maintenance: "externaldrive"
        case .assistant: "sparkles"
        }
    }
}

struct SettingsNavigationSection: Identifiable, Sendable {
    let title: String
    let destinations: [SettingsDestination]
    var id: String { title }
    static let sections = [
        SettingsNavigationSection(title: "Application", destinations: [.general, .accounts, .profiles, .notifications]),
        SettingsNavigationSection(title: "Mail", destinations: [.reading, .messageList, .composing, .signatures, .filters, .blocked, .vacation, .attachments]),
        SettingsNavigationSection(title: "Tools", destinations: [.assistant, .failedChanges, .maintenance])
    ]
}
