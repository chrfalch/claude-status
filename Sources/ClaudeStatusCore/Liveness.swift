import Darwin
import Foundation

public struct Roster: Decodable, Sendable {
    public struct Worker: Decodable, Sendable {
        public let pid: Int32
        public let procStart: String?

        private enum CodingKeys: String, CodingKey { case pid, procStart }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            pid = try fields.decode(Int32.self, forKey: .pid)
            procStart = try? fields.decode(String.self, forKey: .procStart)
        }
    }

    public let workers: [String: Worker]
    public let undecodableWorkerIds: Set<String>

    private enum CodingKeys: String, CodingKey { case workers }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try fields.decode([String: Entry].self, forKey: .workers)
        workers = entries.compactMapValues(\.worker)
        undecodableWorkerIds = Set(entries.filter { $0.value.worker == nil }.keys)
    }

    private struct Entry: Decodable {
        let worker: Worker?

        init(from decoder: Decoder) throws {
            worker = try? Worker(from: decoder)
        }
    }
}

public enum ProcessStart {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = false
        return formatter
    }()

    public static func candidates(_ value: String, localTimeZone: TimeZone = .current) -> [Date] {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lock.lock()
        defer { lock.unlock() }
        return [TimeZone(secondsFromGMT: 0)!, localTimeZone].compactMap { zone in
            formatter.timeZone = zone
            return formatter.date(from: normalized)
        }
    }
}

public enum ProcessLiveness {
    public static func matches(start: Date, candidates: [Date]) -> Bool {
        candidates.isEmpty || candidates.contains { abs(start.timeIntervalSince($0)) <= 2 }
    }

    public static func startTime(pid: Int32) -> Date? {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        let time = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    public static func isAlive(pid: Int32, starts: [Date]) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard !starts.isEmpty else { return true }
        guard let start = startTime(pid: pid) else { return false }
        return matches(start: start, candidates: starts)
    }
}

extension Agent {
    public static func live(
        _ agents: [Agent], roster: Roster?,
        isAlive: (Int32, [Date]) -> Bool
    ) -> [Agent] {
        agents.filter { agent in
            if let pid = agent.pid {
                guard let pid = Int32(exactly: pid) else { return false }
                return isAlive(pid, [])
            }
            guard agent.kind == "background", let id = agent.id, let roster else { return true }
            if roster.undecodableWorkerIds.contains(id) { return true }
            guard let worker = roster.workers[id] else { return false }
            let starts = worker.procStart.map { ProcessStart.candidates($0) } ?? []
            return isAlive(worker.pid, starts)
        }
    }
}
