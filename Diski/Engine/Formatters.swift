import Foundation

/// Shared, cached formatters with Finder's display conventions.
enum Formatters {
    private static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f
    }()

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let longDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = true
        return f
    }()

    private static let preciseBytes: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static var dayBoundaries: (today: Double, yesterday: Double, tomorrow: Double) = computeBoundaries()

    private static func computeBoundaries() -> (today: Double, yesterday: Double, tomorrow: Double) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return (today: today.timeIntervalSince1970, yesterday: yesterday.timeIntervalSince1970,
                tomorrow: tomorrow.timeIntervalSince1970)
    }

    /// Call when the day changes or the locale/time zone changes.
    static func refreshDayBoundaries() {
        dayBoundaries = computeBoundaries()
    }

    /// "Today, 5:15 PM" / "Yesterday, 3:52 PM" / "9/20/26, 8:17 PM".
    static func listDate(_ seconds: Double) -> String {
        guard seconds > 0 else { return "--" }
        if Date().timeIntervalSince1970 >= dayBoundaries.tomorrow { refreshDayBoundaries() }
        let b = dayBoundaries
        let date = Date(timeIntervalSince1970: seconds)
        if seconds >= b.today && seconds < b.tomorrow {
            return "Today, " + timeOnly.string(from: date)
        }
        if seconds >= b.yesterday && seconds < b.today {
            return "Yesterday, " + timeOnly.string(from: date)
        }
        return shortDateTime.string(from: date)
    }

    /// "Sep 20, 2026 at 8:17 PM".
    static func longDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return longDateTime.string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        bytes < 0 ? "--" : byteFormatter.string(fromByteCount: bytes)
    }

    static func preciseSize(_ bytes: Int64) -> String {
        let number = preciseBytes.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(number) bytes"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        let word = n == 1 ? singular : (plural ?? singular + "s")
        return "\(preciseBytes.string(from: NSNumber(value: n)) ?? "\(n)") \(word)"
    }

    /// Transfer speeds: "412 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// Remaining time: "About 12 seconds", "About 3 minutes".
    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 2 { return "Almost done" }
        if seconds < 60 { return "About \(Int(seconds.rounded())) seconds" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "About a minute" : "About \(minutes) minutes" }
        let hours = Double(minutes) / 60
        return String(format: "About %.1f hours", hours)
    }

    /// Elapsed durations for "done" messages: "0.21 s", "3.4 s", "1 min 12 s".
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.2f s", seconds) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m) min \(s) s"
    }
}
