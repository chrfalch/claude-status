import Foundation

/// Task ledgers from github.com/chrfalch/agent-config: `<worktree>/.claude/ledger.md`, titled `# Task ledger — <slug>`.
public enum Ledger {
    // Same match as titleSlug() in agent-config's bin/cc-ledgers.
    private static let heading = try! NSRegularExpression(pattern: #"^# Task ledger[ \t]*(?:—|-)[ \t]*(.*)$"#, options: .anchorsMatchLines)

    public static func title(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = heading.firstMatch(in: text, range: range),
              let slugRange = Range(match.range(at: 1), in: text) else { return nil }
        let slug = text[slugRange].trimmingCharacters(in: .whitespaces)
        return slug.isEmpty || slug.hasPrefix("<") ? nil : slug
    }

    public static func title(forWorktree path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent(".claude/ledger.md")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        return title(in: String(decoding: head, as: UTF8.self))
    }
}
