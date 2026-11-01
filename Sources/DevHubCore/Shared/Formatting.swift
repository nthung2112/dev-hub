import Foundation

/// Where the shared formatters live: `Format.bytes` and `Format.bitRate` sit with the data they
/// format, in `Utilities/`.
public enum Format {}

public enum WorkingDays {
    /// Monday to Friday.
    public static func isWorkingDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDateInWeekend(date)
    }
}
