import Foundation

/// Shared, cached formatters with Finder's display conventions.
enum Formatters {
    /// How much room a date has, narrowest first. Like Finder, list columns
    /// switch to longer formats as they get wider.
    enum DateLength: Int, CaseIterable {
        /// "9/20/26", "Today"
        case dateOnly
        /// "9/20/26, 8:17 PM", "Today, 5:15 PM"
        case short
        /// "Sep 20, 2026 at 8:17 PM", "Today at 5:15 PM"
        case medium
        /// "September 20, 2026 at 8:17 PM"
        case long
        /// "Sunday, September 20, 2026 at 8:17 PM"
        case full
    }

    private static let listDateFormatters: [DateFormatter] = DateLength.allCases.map { length in
        let f = DateFormatter()
        switch length {
        case .dateOnly: f.dateStyle = .short; f.timeStyle = .none
        case .short: f.dateStyle = .short; f.timeStyle = .short
        case .medium: f.dateStyle = .medium; f.timeStyle = .short
        case .long: f.dateStyle = .long; f.timeStyle = .short
        case .full: f.dateStyle = .full; f.timeStyle = .short
        }
        f.locale = Locale.autoupdatingCurrent
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.locale = Locale.autoupdatingCurrent
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    private static let longDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale.autoupdatingCurrent
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    /// List cells ask for the same few dates and sizes on every reload and
    /// scroll: formatted once, keyed by minute and length / by byte count.
    private static let dateStrings: NSCache<NSNumber, NSString> = {
        let cache = NSCache<NSNumber, NSString>()
        cache.countLimit = 4096
        return cache
    }()

    private static let sizeStrings: NSCache<NSNumber, NSString> = {
        let cache = NSCache<NSNumber, NSString>()
        cache.countLimit = 4096
        return cache
    }()

    /// A new locale or time zone moves "Today" and changes every cached string.
    private static let changeObservers: [NSObjectProtocol] = {
        let names: [Notification.Name] = [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange]
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Formatters.refreshDayBoundaries()
                Formatters.sizeStrings.removeAllObjects()
            }
        }
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
        dateStrings.removeAllObjects()
    }

    /// "Today, 5:15 PM" / "Yesterday, 3:52 PM" / "9/20/26, 8:17 PM" (`.short`).
    static func listDate(_ seconds: Double, length: DateLength = .short) -> String {
        guard seconds > 0 else { return "--" }
        _ = changeObservers
        if Date().timeIntervalSince1970 >= dayBoundaries.tomorrow { refreshDayBoundaries() }
        // Every format stops at minutes and day boundaries fall on whole
        // minutes, so one string serves a whole minute.
        let key: NSNumber? = seconds < 1e13 ? NSNumber(value: Int64(seconds / 60) &* 8 &+ Int64(length.rawValue)) : nil
        if let key, let cached = dateStrings.object(forKey: key) { return cached as String }
        let text = formatListDate(seconds, length: length)
        if let key { dateStrings.setObject(text as NSString, forKey: key) }
        return text
    }

    private static func formatListDate(_ seconds: Double, length: DateLength) -> String {
        let b = dayBoundaries
        let date = Date(timeIntervalSince1970: seconds)
        let relative = seconds >= b.today && seconds < b.tomorrow ? "Today"
            : seconds >= b.yesterday && seconds < b.today ? "Yesterday" : nil
        guard let relative else { return listDateFormatters[length.rawValue].string(from: date) }
        switch length {
        case .dateOnly: return relative
        case .short: return relative + ", " + timeOnly.string(from: date)
        case .medium, .long, .full: return relative + " at " + timeOnly.string(from: date)
        }
    }

    /// "Sep 20, 2026 at 8:17 PM".
    static func longDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return longDateTime.string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        if bytes < 0 { return "--" }
        // Finder's wording for empty items (the formatter would say "Zero KB").
        if bytes == 0 { return "Zero bytes" }
        _ = changeObservers
        let key = NSNumber(value: bytes)
        if let cached = sizeStrings.object(forKey: key) { return cached as String }
        let text = byteFormatter.string(fromByteCount: bytes)
        sizeStrings.setObject(text as NSString, forKey: key)
        return text
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
