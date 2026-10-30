import Foundation

public enum Transcript {
    private static let initialTailSize: UInt64 = 256 * 1024
    private static let maximumTailSize: UInt64 = 8 * 1024 * 1024

    public static let projectsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    public struct Activity: Equatable, Sendable {
        public let lastModified: Date
        public let runningSubagents: Int
    }

    /// The transcript is written on every turn, so its modification date is the session's last activity.
    public static func activity(sessionIds: Set<String>, projectsDirectory: URL = projectsDirectory, now: Date = Date()) -> [String: Activity] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
        var activity: [String: Activity] = [:]
        for directory in directories {
            for sessionId in sessionIds where activity[sessionId] == nil {
                guard let date = modificationDate(directory.appendingPathComponent("\(sessionId).jsonl")) else { continue }
                let subagents = directory.appendingPathComponent(sessionId).appendingPathComponent("subagents")
                activity[sessionId] = Activity(lastModified: date, runningSubagents: runningSubagents(in: subagents, now: now))
            }
        }
        return activity
    }

    // Sub-agents that were killed, or written by older Claude Code versions, never get "finished": true,
    // so an unfinished one also needs a recently written log to count as running.
    private static let subagentQuietLimit: TimeInterval = 15 * 60

    private static func runningSubagents(in directory: URL, now: Date) -> Int {
        struct Meta: Decodable { let finished: Bool? }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { file in
            guard file.lastPathComponent.hasSuffix(".meta.json"),
                  let meta = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(Meta.self, from: $0) }),
                  meta.finished != true else { return false }
            let log = directory.appendingPathComponent(file.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            return modificationDate(log).map { now.timeIntervalSince($0) < subagentQuietLimit } ?? false
        }.count
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func lastText(in data: Data) -> String? {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(line)),
                  record.type == "assistant",
                  record.isSidechain != true else { continue }

            let items = record.message?.content.filter { $0.type == "text" } ?? []
            if !items.isEmpty {
                return items.compactMap(\.text).joined(separator: "\n")
            }
        }
        return nil
    }

    public static func lastText(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var tailSize = min(initialTailSize, fileSize)

        while true {
            let offset = fileSize - tailSize
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: Int(tailSize)) ?? Data()
            if offset > 0, let newline = data.firstIndex(of: 0x0A) {
                data = data[data.index(after: newline)...]
            } else if offset > 0 {
                data.removeAll()
            }

            if let text = lastText(in: data) { return text }
            if offset == 0 || tailSize >= maximumTailSize { return nil }
            tailSize = min(fileSize, min(maximumTailSize, tailSize * 2))
        }
    }

    private struct Record: Decodable {
        let type: String?
        let isSidechain: Bool?
        let message: Message?
    }

    private struct Message: Decodable {
        let content: [Content]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = (try? container.decode([Content].self, forKey: .content)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case content }
    }

    private struct Content: Decodable {
        let type: String?
        let text: String?
    }
}

public actor TranscriptStore {
    private let projectsDirectory: URL
    private let now: @Sendable () -> Date
    internal private(set) var readCount = 0
    internal private(set) var globCount = 0
    private struct Entry {
        let modified: Date
        let size: UInt64
        let text: String?
    }
    private var entries: [String: Entry] = [:]
    private var missing: [String: Date] = [:]
    private var transcriptURLs: [String: URL] = [:]

    public init(projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.projectsDirectory = projectsDirectory
        self.now = { Date() }
    }

    internal init(projectsDirectory: URL, now: @escaping @Sendable () -> Date) {
        self.projectsDirectory = projectsDirectory
        self.now = now
    }

    public func prune(sessionIds: Set<String>) {
        entries = entries.filter { sessionIds.contains($0.key) }
        missing = missing.filter { sessionIds.contains($0.key) }
        transcriptURLs = transcriptURLs.filter { sessionIds.contains($0.key) }
    }

    public func lastText(sessionId: String) async -> String? {
        guard let url = transcriptURL(sessionId: sessionId) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? UInt64 else { return nil }
        if let entry = entries[sessionId], entry.modified == modified, entry.size == size {
            return entry.text
        }
        readCount += 1
        do {
            let text = try Transcript.lastText(at: url)
            entries[sessionId] = Entry(modified: modified, size: size, text: text)
            return text
        } catch {
            return nil
        }
    }

    private func transcriptURL(sessionId: String) -> URL? {
        let fileManager = FileManager.default
        if let cached = transcriptURLs[sessionId], fileManager.fileExists(atPath: cached.path) {
            return cached
        }

        if let lastMiss = missing[sessionId], now().timeIntervalSince(lastMiss) < 60 { return nil }
        transcriptURLs[sessionId] = nil
        entries[sessionId] = nil
        globCount += 1
        missing[sessionId] = now()
        let filename = "\(sessionId).jsonl"
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for directory in projectDirectories {
            let candidate = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: candidate.path) {
                missing[sessionId] = nil
                transcriptURLs[sessionId] = candidate
                return candidate
            }
        }
        transcriptURLs[sessionId] = nil
        return nil
    }
}
