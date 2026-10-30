import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func lastAssistantText() {
    let lines = #"""
    {"type":"assistant","message":{"content":[{"type":"text","text":"older"}]}}
    broken JSON
    {"type":"user","message":{"content":[{"type":"text","text":"user"}]}}
    {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"first"},{"type":"thinking","thinking":"secret"},{"type":"text","text":"second"}]}}
    {"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sidechain"}]}}
    {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret"}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"read"}]}}
    invalid last line
    """#
    #expect(Transcript.lastText(in: Data(lines.utf8)) == "first\nsecond")
    #expect(Transcript.lastText(in: Data("bad\n{}".utf8)) == nil)
}

@Test func transcriptTailGrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let record = #"{"type":"assistant","message":{"content":[{"type":"text","text":"near the start"}]}}"#
    let contents = record + "\n" + String(repeating: "{\"type\":\"mode\"}\n", count: 40_000)
    try Data(contents.utf8).write(to: url)
    #expect(try Transcript.lastText(at: url) == "near the start")
}

@Test func transcriptTailDropsPartialLine() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let record = #"{"type":"assistant","message":{"content":[{"type":"text","text":"last"}]}}"#
    try Data((String(repeating: "x", count: 300_000) + "\n" + record).utf8).write(to: url)
    #expect(try Transcript.lastText(at: url) == "last")
}

@Test func transcriptStoreCachesReadsAndGrowth() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = project.appendingPathComponent("a.jsonl")
    let first = #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"# + "\n"
    try Data(first.utf8).write(to: url)
    let store = TranscriptStore(projectsDirectory: root)
    #expect(await store.lastText(sessionId: "a") == "first")
    #expect(await store.lastText(sessionId: "a") == "first")
    #expect(await store.readCount == 1)
    let second = #"{"type":"assistant","message":{"content":[{"type":"text","text":"second"}]}}"#
    try Data((first + second).utf8).write(to: url)
    #expect(await store.lastText(sessionId: "a") == "second")
    #expect(await store.readCount == 2)
    await store.prune(sessionIds: [])
    #expect(await store.lastText(sessionId: "a") == "second")
    #expect(await store.readCount == 3)
}

@Test func transcriptStoreCachesMissingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock()
    let store = TranscriptStore(projectsDirectory: root, now: { clock.now })
    #expect(await store.lastText(sessionId: "missing") == nil)
    #expect(await store.lastText(sessionId: "missing") == nil)
    #expect(await store.globCount == 1)
    clock.advance(61)
    #expect(await store.lastText(sessionId: "missing") == nil)
    #expect(await store.globCount == 2)
    await store.prune(sessionIds: [])
    #expect(await store.lastText(sessionId: "missing") == nil)
    #expect(await store.globCount == 3)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

@Test func transcriptModificationDates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("s1.jsonl")
    try Data("{}".utf8).write(to: file)
    let date = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    let activity = Transcript.activity(sessionIds: ["s1", "missing"], projectsDirectory: root)
    #expect(activity["s1"]?.lastModified == date)
    #expect(activity["s1"]?.runningSubagents == 0)
    #expect(activity["missing"] == nil)
}

@Test func runningSubagentsAreUnfinishedAndRecent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let subagents = root.appendingPathComponent("project/s1/subagents")
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("project/s1.jsonl"))
    let now = Date(timeIntervalSince1970: 10_000)
    func agent(_ id: String, meta: String, modified: Date?) throws {
        try Data(meta.utf8).write(to: subagents.appendingPathComponent("agent-\(id).meta.json"))
        guard let modified else { return }
        let log = subagents.appendingPathComponent("agent-\(id).jsonl")
        try Data("{}".utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: log.path)
    }
    try agent("running", meta: #"{"agentType":"runner"}"#, modified: now.addingTimeInterval(-60))
    try agent("explicit", meta: #"{"finished":false}"#, modified: now.addingTimeInterval(-60))
    try agent("finished", meta: #"{"finished":true}"#, modified: now.addingTimeInterval(-60))
    try agent("stale", meta: #"{}"#, modified: now.addingTimeInterval(-3600))
    try agent("nolog", meta: #"{}"#, modified: nil)
    let activity = Transcript.activity(sessionIds: ["s1", "missing"], projectsDirectory: root, now: now)
    #expect(activity["s1"]?.runningSubagents == 2)
    #expect(activity["missing"] == nil)
}
