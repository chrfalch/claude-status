import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func ledgerTitleFromHeading() {
    #expect(Ledger.title(in: "# Task ledger — spm-cocoapods-opt-out\n\nRead this first.") == "spm-cocoapods-opt-out")
    #expect(Ledger.title(in: "intro\n# Task ledger - ruby2ts  \n") == "ruby2ts")
    #expect(Ledger.title(in: "# Task ledger — <slug>\n") == nil)
    #expect(Ledger.title(in: "# Task ledger — \n") == nil)
    #expect(Ledger.title(in: "# Notes\n") == nil)
}

@Test func ledgerTitleFromWorktree() throws {
    let worktree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = worktree.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: worktree) }
    #expect(Ledger.title(forWorktree: worktree.path) == nil)
    try "# Task ledger — reader-rotation-lock\n".write(to: folder.appendingPathComponent("ledger.md"), atomically: true, encoding: .utf8)
    #expect(Ledger.title(forWorktree: worktree.path) == "reader-rotation-lock")
}

@Test func ledgerTitleWinsOverAgentName() throws {
    let data = Data(#"[{"name":"agent-name","cwd":"/tmp/x","status":"idle"}]"#.utf8)
    var agent = try #require(Agent.decode(data).first)
    #expect(agent.displayName == "agent-name")
    agent.ledgerTitle = "ledger-slug"
    #expect(agent.displayName == "ledger-slug")
    #expect(agent.menuLabel == "ledger-slug — idle")
}
