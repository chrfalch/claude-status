import Foundation

/// Rate limit windows of one provider, each shown as a gauge.
public struct Usage: Sendable {
    public struct Window: Sendable {
        public let length: TimeInterval
        public let usedPercentage: Double?
        public let resetsAt: Double?
    }

    public struct Gauge: Sendable {
        public let name: String
        /// Share of the limit used, 0...1, or nil when the window has reset since the data was saved.
        public let used: Double?
        /// Share of the window's time that has passed, 0...1.
        public let elapsed: Double?
        public let detail: String
        /// The days of a week window, for drawing it in day parts.
        public let days: [Day]?
        public let pace: Pace?
    }

    /// How the use compares with an even spread over the window.
    public struct Pace: Equatable, Sendable {
        public enum Level: Sendable { case calm, ahead, over }
        public let level: Level
        public let text: String
    }

    public struct Day: Sendable {
        public let symbol: String
        public let isWeekend: Bool
    }

    public static let sessionLength: TimeInterval = 5 * 3600
    public static let weekLength: TimeInterval = 7 * 86400

    public let windows: [Window]
    /// When the numbers were read from the provider; nil when unknown.
    public let fetchedAt: Date?

    public init(windows: [Window], fetchedAt: Date? = nil) {
        self.windows = windows.sorted { $0.length < $1.length }
        self.fetchedAt = fetchedAt
    }

    public func with(fetchedAt: Date?) -> Usage { Usage(windows: windows, fetchedAt: fetchedAt) }

    public static func newest(_ usages: [Usage?]) -> Usage? {
        usages.compactMap { $0 }.max { ($0.fetchedAt ?? .distantPast) < ($1.fetchedAt ?? .distantPast) }
    }

    private static let staleAge: TimeInterval = 5 * 60

    public func ageText(now: Date, calendar: Calendar = .current) -> String? {
        guard let fetchedAt, now.timeIntervalSince(fetchedAt) >= Self.staleAge else { return nil }
        let format = calendar.isDate(fetchedAt, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return "as of \(Self.format(fetchedAt, format, calendar: calendar))"
    }

    static func format(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: Claude

    /// Saved by the Claude Code status line command from its `rate_limits` input.
    public static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/state/rate-limits.json")

    public static func decode(_ data: Data) -> Usage? {
        struct Window: Decodable {
            let used_percentage: Double?
            let resets_at: Double?
        }
        struct Limits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
        guard let limits = try? JSONDecoder().decode(Limits.self, from: data) else { return nil }
        return Usage(windows: [(limits.five_hour, sessionLength), (limits.seven_day, weekLength)].compactMap { window, length in
            window.map { Usage.Window(length: length, usedPercentage: $0.used_percentage, resetsAt: $0.resets_at) }
        })
    }

    /// Claude Code keeps the last numbers it fetched in its config file, also when the status line never runs.
    public static let claudeConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

    public static func decodeClaudeConfig(_ data: Data) -> Usage? {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct Limits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
        struct Cache: Decodable {
            let fetchedAtMs: Double?
            let utilization: Limits?
        }
        struct Config: Decodable {
            let cachedUsageUtilization: Cache?
        }
        guard let cache = (try? JSONDecoder().decode(Config.self, from: data))?.cachedUsageUtilization,
              let limits = cache.utilization else { return nil }
        return Usage(
            windows: [(limits.five_hour, sessionLength), (limits.seven_day, weekLength)].compactMap { window, length in
                window.map { Usage.Window(length: length, usedPercentage: $0.utilization, resetsAt: $0.resets_at.flatMap(unixTime)) }
            },
            fetchedAt: cache.fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // ISO8601DateFormatter reads at most milliseconds, and these dates carry microseconds.
    private static func unixTime(_ iso: String) -> Double? {
        let parts = iso.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let zone = parts[1].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else {
            return ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970
        }
        guard let whole = ISO8601DateFormatter().date(from: String(parts[0]) + parts[1][zone...]) else { return nil }
        return Double("\(Int(whole.timeIntervalSince1970)).\(parts[1][..<zone])")
    }

    // MARK: Codex

    public static let codexSessions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    /// The last `codex` limits that Codex wrote to a session log, in its `token_count` events.
    public static func codex(sessionLog data: Data) -> Usage? {
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Double?
            let resets_at: Double?
        }
        struct Limits: Decodable {
            let limit_id: String?
            let primary: Window?
            let secondary: Window?
        }
        struct Payload: Decodable {
            let type: String?
            let rate_limits: Limits?
        }
        struct Record: Decodable {
            let payload: Payload?
        }
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let limits = (try? decoder.decode(Record.self, from: Data(line)))?.payload?.rate_limits,
                  limits.limit_id == "codex" else { continue }
            let windows = [limits.primary, limits.secondary].compactMap { window -> Usage.Window? in
                guard let window, let minutes = window.window_minutes else { return nil }
                return Usage.Window(length: minutes * 60, usedPercentage: window.used_percent, resetsAt: window.resets_at)
            }
            return windows.isEmpty ? nil : Usage(windows: windows)
        }
        return nil
    }

    /// A session started on an earlier day can still be the active one, so this picks by modification date.
    public static func newestCodexSessionLog(in sessions: URL = codexSessions) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys) else { return nil }
        var newest: (url: URL, modified: Date)?
        for case let url as URL in files where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
            if modified > newest?.modified ?? .distantPast { newest = (url, modified) }
        }
        return newest?.url
    }

    // MARK: Gauges

    public func gauges(now: Date, calendar: Calendar = .current) -> [Gauge] {
        windows.compactMap { Self.gauge($0, now: now, calendar: calendar) }
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

    private static func name(_ length: TimeInterval) -> String {
        switch length {
        case sessionLength: "Session"
        case weekLength: "Week"
        default: "\(Int(length / 3600))h"
        }
    }

    private static func gauge(_ window: Window, now: Date, calendar: Calendar) -> Gauge? {
        let name = name(window.length)
        let remaining = window.resetsAt.map { $0 - now.timeIntervalSince1970 }
        let days = window.length == weekLength ? window.resetsAt.map { weekDays(endingAt: Date(timeIntervalSince1970: $0), calendar: calendar) } : nil
        // The saved percentage belongs to the window that has ended, so it says nothing about the new one.
        if let remaining, remaining <= 0 { return Gauge(name: name, used: nil, elapsed: nil, detail: "reset", days: nil, pace: nil) }
        guard let percentage = window.usedPercentage else { return nil }
        let used = "\(Int(percentage.rounded()))%"
        let elapsed = remaining.map { min(1, max(0, 1 - $0 / window.length)) }
        return Gauge(
            name: name,
            used: min(1, max(0, percentage / 100)),
            elapsed: elapsed,
            detail: remaining.map { "\(used) · resets in \(duration($0))" } ?? used,
            days: days,
            pace: elapsed.flatMap { elapsed in
                window.resetsAt.flatMap { pace(used: percentage / 100, elapsed: elapsed, start: $0 - window.length, length: window.length, now: now, calendar: calendar) }
            }
        )
    }

    // Points, not a ratio: early in a window a few percent used would read as a large ratio.
    private static func pace(used: Double, elapsed: Double, start: Double, length: TimeInterval, now: Date, calendar: Calendar) -> Pace? {
        guard elapsed >= 0.05 else { return nil }
        let points = Int(((used - elapsed) * 100).rounded())
        switch points {
        case ..<(-4): return Pace(level: .calm, text: "\(-points) pts under")
        case ..<5: return Pace(level: .calm, text: "on pace")
        case ..<15: return Pace(level: .ahead, text: "\(points) pts ahead")
        default:
            let runsOut = Date(timeIntervalSince1970: start + length * elapsed / used)
            let format = calendar.isDate(runsOut, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
            return Pace(level: .over, text: "out \(Self.format(runsOut, format, calendar: calendar))")
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours >= 1 { return "\(hours)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }
}
