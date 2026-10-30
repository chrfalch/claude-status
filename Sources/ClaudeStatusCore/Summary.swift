import Foundation

public enum Summary {
    public static func plainText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map(stripLinePrefix)
            .joined(separator: " ")
            .replacingOccurrences(of: "[*`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\((?:[^()]|\([^()]*\))*\)"#, with: "$1", options: .regularExpression)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    public static func input(_ text: String, maxCharacters: Int = 4_000) -> String {
        String(text.suffix(max(0, maxCharacters)))
    }

    public static func twoLines(_ text: String, maxCharsPerLine: Int = 60) -> String {
        let normalized = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, maxCharsPerLine > 0 else { return "" }
        guard normalized.count > maxCharsPerLine else { return normalized }

        let breakIndex = normalized.prefix(maxCharsPerLine + 1).lastIndex(of: " ")
            ?? normalized.index(normalized.startIndex, offsetBy: maxCharsPerLine)
        let first = String(normalized[..<breakIndex])
        let remainderStart = normalized[breakIndex] == " "
            ? normalized.index(after: breakIndex)
            : breakIndex
        let remainder = String(normalized[remainderStart...])

        if remainder.count <= maxCharsPerLine {
            return "\(first)\n\(remainder)"
        }
        if maxCharsPerLine == 1 { return "\(first)\n…" }
        let end = remainder.prefix(maxCharsPerLine).lastIndex(of: " ")
            ?? remainder.index(remainder.startIndex, offsetBy: maxCharsPerLine - 1)
        return "\(first)\n\(remainder[..<end])…"
    }

    private static func stripLinePrefix(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^\s*(?:#+\s*|[-*+]\s+|\d+[.)]\s+)"#,
            with: "",
            options: .regularExpression
        )
    }
}

public actor SummaryCache {
    public typealias Summarizer = @Sendable (String) async throws -> String

    private struct Entry {
        let text: String
        let fallbackAt: Date?
        let summary: String
    }

    private let now: @Sendable () -> Date
    private let summarize: Summarizer
    private var entries: [String: Entry] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }, _ summarize: @escaping Summarizer) {
        self.now = now
        self.summarize = summarize
    }

    public func prune(sessionIds: Set<String>) {
        entries = entries.filter { sessionIds.contains($0.key) }
    }

    public func summary(sessionId: String, text: String) async -> String {
        if let entry = entries[sessionId], entry.text == text,
           entry.fallbackAt.map({ now().timeIntervalSince($0) < 300 }) ?? true {
            return entry.summary
        }

        let result: String
        let fallbackAt: Date?
        do {
            result = try await summarize(text)
            fallbackAt = nil
        } catch {
            fallbackAt = now()
            result = Summary.plainText(text)
        }
        entries[sessionId] = Entry(text: text, fallbackAt: fallbackAt, summary: result)
        return result
    }
}
