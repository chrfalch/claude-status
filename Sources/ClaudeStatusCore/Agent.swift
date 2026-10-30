import Foundation

public struct Agent: Decodable, Sendable {
    public let startedAt: Double?
    public let cwd: String?
    public let name: String?
    public let id: String?
    public let status: String?
    public let kind: String?
    public let state: String?
    public let pid: Int?
    public let sessionId: String?
    public var ledgerTitle: String?
    public var lastActivity: Date?
    public var runningSubagents = 0
    public var shellCommands = 0

    enum CodingKeys: String, CodingKey {
        case startedAt, cwd, name, id, status, kind, state, pid, sessionId
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try? fields.decode(Double.self, forKey: .startedAt)
        cwd = try? fields.decode(String.self, forKey: .cwd)
        name = try? fields.decode(String.self, forKey: .name)
        id = try? fields.decode(String.self, forKey: .id)
        status = try? fields.decode(String.self, forKey: .status)
        kind = try? fields.decode(String.self, forKey: .kind)
        state = try? fields.decode(String.self, forKey: .state)
        pid = try? fields.decode(Int.self, forKey: .pid)
        sessionId = try? fields.decode(String.self, forKey: .sessionId)
    }

    public static func decode(_ data: Data) throws -> [Agent] {
        try JSONDecoder().decode([Entry].self, from: data).compactMap(\.agent)
    }

    private struct Entry: Decodable {
        let agent: Agent?
        init(from decoder: Decoder) throws {
            agent = try? Agent(from: decoder)
        }
    }

    public var resolvedStatus: AgentStatus { AgentStatus(rawValue: state ?? status) }

    /// An idle session can still wait for its background commands or sub-agents, and these keep the work going.
    public var activity: Activity {
        let activity = resolvedStatus.activity
        return activity == .idle && (shellCommands > 0 || runningSubagents > 0) ? .working : activity
    }

    public var menuLabel: String {
        let suffix = resolvedStatus.unknownRawValue.map { " (unknown: \($0))" } ?? ""
        return "\(displayName) — \(activity.label)\(suffix)"
    }

    public var displayName: String {
        if let ledgerTitle, !ledgerTitle.isEmpty { return ledgerTitle }
        if let name, !name.isEmpty { return name }
        if let cwd, !cwd.isEmpty {
            let component = URL(fileURLWithPath: cwd).lastPathComponent
            if !component.isEmpty { return component }
        }
        if let sessionId, !sessionId.isEmpty { return sessionId }
        return "unnamed"
    }

    public static func sorted(_ agents: [Agent]) -> [Agent] {
        agents.sorted {
            let left = $0.activity.rawValue
            let right = $1.activity.rawValue
            if left != right { return left < right }
            switch ($0.lastActivity, $1.lastActivity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

public enum Activity: Int, Sendable {
    case waiting, working, idle

    public var label: String {
        switch self {
        case .waiting: "waiting"
        case .working: "working"
        case .idle: "idle"
        }
    }

    public static func aggregate(_ activities: [Activity]) -> Activity {
        activities.min(by: { $0.rawValue < $1.rawValue }) ?? .idle
    }
}

public struct AgentStatus: Sendable {
    public let activity: Activity
    public let unknownRawValue: String?

    public init(rawValue: String?) {
        let raw = rawValue?.lowercased()
        switch raw {
        case "blocked", "waiting", "needs_input", "awaiting_input", "permission", "input":
            activity = .waiting
            unknownRawValue = nil
        case "busy", "running", "working", "active", "thinking":
            activity = .working
            unknownRawValue = nil
        case "idle", "done", "completed", "finished", "stopped":
            activity = .idle
            unknownRawValue = nil
        default:
            activity = .working
            unknownRawValue = raw
        }
    }
}
