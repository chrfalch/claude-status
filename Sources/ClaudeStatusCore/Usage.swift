import Foundation

/// Claude rate limits as saved by the status line command from its `rate_limits` input.
public struct Usage: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercentage: Double?
        public let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/state/rate-limits.json")

    public static func decode(_ data: Data) -> Usage? {
        try? JSONDecoder().decode(Usage.self, from: data)
    }

    public struct Gauge: Sendable {
        public let name: String
        /// Share of the limit used, 0...1, or nil when the window has reset since the data was saved.
        public let used: Double?
        /// Share of the window's time that has passed, 0...1.
        public let elapsed: Double?
        public let detail: String
    }

    public struct Day: Sendable {
        public let symbol: String
        public let isWeekend: Bool
    }

    public static let sessionLength: TimeInterval = 5 * 3600
    public static let weekLength: TimeInterval = 7 * 86400

    public func gauges(now: Date) -> [Gauge] {
        [("Session", fiveHour, Self.sessionLength), ("Week", sevenDay, Self.weekLength)].compactMap { name, window, length in
            window.flatMap { Self.gauge(name, $0, length: length, now: now) }
        }
    }

    /// One day per 24 hours of the week window, named by the weekday at the middle of that day.
    public static func weekDays(endingAt end: Date, calendar: Calendar = .current) -> [Day] {
        let start = end.addingTimeInterval(-weekLength)
        return (0..<7).map { index in
            let middle = start.addingTimeInterval((Double(index) + 0.5) * 86400)
            let weekday = calendar.component(.weekday, from: middle)
            return Day(symbol: calendar.veryShortWeekdaySymbols[weekday - 1], isWeekend: calendar.isDateInWeekend(middle))
        }
    }

    private static func gauge(_ name: String, _ window: Window, length: TimeInterval, now: Date) -> Gauge? {
        let remaining = window.resetsAt.map { $0 - now.timeIntervalSince1970 }
        // The saved percentage belongs to the window that has ended, so it says nothing about the new one.
        if let remaining, remaining <= 0 { return Gauge(name: name, used: nil, elapsed: nil, detail: "reset") }
        guard let percentage = window.usedPercentage else { return nil }
        let used = "\(Int(percentage.rounded()))%"
        return Gauge(
            name: name,
            used: min(1, max(0, percentage / 100)),
            elapsed: remaining.map { min(1, max(0, 1 - $0 / length)) },
            detail: remaining.map { "\(used) · resets in \(duration($0))" } ?? used
        )
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours >= 1 { return "\(hours)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }
}
