import Foundation

/// The date and size filters in the shape the filter form edits. Dates hold
/// the start of a day; sizes are edited in megabytes and stored in bytes.
extension AttachmentLibraryModel {
    /// Turning the filter on starts it today.
    var hasStartDate: Bool {
        get { startDate != nil }
        set { startDate = newValue ? Self.day(of: .now) : nil }
    }

    var startDay: Date {
        get { startDate ?? Self.day(of: .now) }
        set { startDate = Self.day(of: newValue) }
    }

    /// Turning the filter on ends it today.
    var hasEndDate: Bool {
        get { endDate != nil }
        set { endDate = newValue ? Self.day(of: .now) : nil }
    }

    var endDay: Date {
        get { endDate ?? Self.day(of: .now) }
        set { endDate = Self.day(of: newValue) }
    }

    var minimumMegabytes: Double? {
        get { minimumSize.map(Self.megabytes) }
        set { minimumSize = newValue.flatMap(Self.bytes) }
    }

    var maximumMegabytes: Double? {
        get { maximumSize.map(Self.megabytes) }
        set { maximumSize = newValue.flatMap(Self.bytes) }
    }

    private static func day(of date: Date) -> Date { Calendar.current.startOfDay(for: date) }

    private static func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_000_000 }

    /// `nil`, which reads as Any, for sizes a byte count can't hold.
    private static func bytes(_ megabytes: Double) -> Int? {
        guard megabytes.isFinite, megabytes >= 0, megabytes < Double(Int.max) / 1_000_000 else { return nil }
        return Int(megabytes * 1_000_000)
    }
}
