import AppKit
import Foundation
import GmailAPI
import SwiftUI

enum CalendarDisplayMode: String, CaseIterable, Identifiable {
    case day, week, month, year, schedule
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The `UserDefaults` key under which the view keeps the last chosen mode.
    static let storageKey = "calendarDisplayMode"
    /// The span ⌥← and ⌥→ move by.
    var component: Calendar.Component {
        switch self { case .day: .day; case .week: .weekOfYear; case .month, .schedule: .month; case .year: .year }
    }
    /// The span bare ← and → move by: a day in Day and Week, a week in Month, a month in Year.
    var stepComponent: Calendar.Component {
        switch self { case .day, .week, .schedule: .day; case .month: .weekOfYear; case .year: .month }
    }
}

/// Where the calendar keeps its view preferences. The UI audit uses its own
/// suite so a preview run never changes the user's settings.
enum CalendarDefaults {
    @MainActor static let store: UserDefaults = {
        let arguments = ProcessInfo.processInfo.arguments
        let isAudit = arguments.contains("--ui-audit") || arguments.contains("--ui-audit-calendar")
        return isAudit ? UserDefaults(suiteName: "tern.calendar.audit") ?? .standard : .standard
    }()
}

enum CalendarAIAccess: String, CaseIterable, Identifiable {
    case off, availability, details
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .availability: "Availability Only"; case .details: "Event Details" }
    }
}

struct CalendarAccountOption: Identifiable, Hashable {
    var id: String
    var title: String
    var email = ""
    var canManage = false
    var canShare = false
}

struct CalendarDisplayCalendar: Identifiable, Equatable {
    var entry: GoogleCalendarEntry
    var accountID: String
    var accountName: String
    var isVisible = true
    var aiAccess: CalendarAIAccess = .off
    var useForScheduling = false
    var canManage = false
    var canShare = false
    var notificationsEnabled = false
    var id: String { Self.key(accountID: accountID, calendarID: entry.id) }
    var calendarID: String { entry.id }
    var title: String { entry.title }
    var canWrite: Bool { entry.canWrite }
    var colorHex: String { entry.backgroundColor ?? "#4285f4" }
    var color: Color { Color(calendarHex: colorHex) }

    static func key(accountID: String, calendarID: String) -> String {
        "\(accountID.utf8.count):\(accountID)\(calendarID)"
    }
}

struct CalendarDisplayEvent: Identifiable, Equatable {
    var event: GoogleCalendarEvent
    var accountID: String
    var calendarID: String
    var colorHex = "#4285f4"
    var isPending = false
    var canEdit = true
    var fallbackTimeZoneID = TimeZone.current.identifier
    var id: String { "\(calendarKey)|\(event.id)" }
    var calendarKey: String { CalendarDisplayCalendar.key(accountID: accountID, calendarID: calendarID) }
    var title: String { event.summary?.isEmpty == false ? event.summary ?? "" : "Untitled event" }
    var start: Date { event.start?.resolvedDate(fallbackTimeZone: TimeZone(identifier: fallbackTimeZoneID) ?? .autoupdatingCurrent) ?? .distantPast }
    var end: Date { event.end?.resolvedDate(fallbackTimeZone: TimeZone(identifier: fallbackTimeZoneID) ?? .autoupdatingCurrent) ?? start }
    var isAllDay: Bool { event.isAllDay }
    var color: Color { Color(calendarHex: colorHex) }
    var isRecurring: Bool { event.recurringEventId != nil || !(event.recurrence ?? []).isEmpty }
}

enum CalendarEditScope: String, CaseIterable, Identifiable {
    case occurrence, series, following
    var id: String { rawValue }
    var title: String {
        switch self { case .occurrence: "This event"; case .series: "All events"; case .following: "This and following events" }
    }
}

struct CalendarEditorDraft: Identifiable {
    var id = UUID()
    var event: GoogleCalendarEvent
    var calendarKey: String
    var source: CalendarDisplayEvent?
    var editScope: CalendarEditScope = .occurrence
    var createMeet = false
    var isImport = false
    var isDeletion = false
    var importedExceptions: [GoogleCalendarEvent] = []
    var followingExceptionsCount: Int?
    var acknowledgesFollowingReset = false
    var sourceTitle: String?
    var sourceID: String?
    var operationID: String?
    var seriesMaster: GoogleCalendarEvent?
    var additionalNotificationRecipients: [String] = []
    var sourceEvent: GoogleCalendarEvent? { source?.event }
    var isNew: Bool { source == nil }
}

struct CalendarShare: Identifiable, Equatable {
    var id: String
    var email: String
    var role: String
    var scopeType = "user"
    var etag: String? = nil
}

extension Color {
    /// Google's calendar hue, resolved per appearance: Dark lifts the luminance
    /// so chips stay readable on dark surfaces, Increase Contrast deepens the hue.
    init(calendarHex: String) {
        guard let components = CalendarColor.components(hex: calendarHex) else { self = .accentColor; return }
        self.init(nsColor: NSColor(name: nil) { appearance in CalendarColor.resolve(components, for: appearance) })
    }
}

enum CalendarColor {
    struct Components: Equatable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
    }

    /// How much Dark lifts a calendar hue's brightness.
    private static let darkLift: CGFloat = 1.25
    /// The brightness floor Dark starts from, so near-black hues still read.
    private static let darkFloor: CGFloat = 0.55
    /// How much Increase Contrast deepens the saturation.
    private static let contrastSaturation: CGFloat = 1.2

    static func components(hex: String) -> Components? {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return Components(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                          blue: CGFloat(rgb & 255) / 255)
    }

    static func resolve(_ components: Components, for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua])
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let isContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        return adjusted(components, dark: isDark, contrast: isContrast)
    }

    static func adjusted(_ components: Components, dark: Bool, contrast: Bool) -> NSColor {
        let base = NSColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: 1)
        guard dark || contrast else { return base }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if dark { brightness = min(1, max(brightness, darkFloor) * darkLift) }
        if contrast { saturation = min(1, saturation * contrastSaturation) }
        return NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    /// The tint behind an event's text. Increase Contrast strengthens it so the
    /// calendar hue stays distinguishable from the surface.
    static func tint(_ base: Double, contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? min(1, base * 2) : base
    }
}

enum CalendarLayout {
    static func format(_ date: Date, style: Date.FormatStyle, calendar: Calendar) -> String {
        var value = style
        value.calendar = calendar
        value.timeZone = calendar.timeZone
        return date.formatted(value)
    }

    static func days(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end, result.count < 370 {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }

    static func monthDays(containing date: Date, calendar: Calendar) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: firstWeek.start) }
    }

    static func events(_ events: [CalendarDisplayEvent], on day: Date, calendar: Calendar) -> [CalendarDisplayEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return events.filter { $0.start < interval.end && max($0.end, $0.start.addingTimeInterval(1)) > interval.start }
            .sorted { $0.isAllDay == $1.isAllDay ? $0.start < $1.start : $0.isAllDay }
    }

    static func date(at minutes: Int, on day: Date, calendar: Calendar) -> Date {
        let hour = min(23, max(0, minutes / 60)), minute = min(59, max(0, minutes % 60))
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}
