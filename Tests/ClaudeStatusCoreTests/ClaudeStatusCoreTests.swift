import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func decodesInteractive() throws {
    let agents = try Agent.decode(Data(#"[{"pid":8108,"cwd":"/some/path","kind":"interactive","startedAt":1793094553199,"sessionId":"abc","name":"spm-ecosystem-prs","status":"idle"}]"#.utf8))
    let agent = try #require(agents.first)
    #expect(agent.pid == 8108)
    #expect(agent.cwd == "/some/path")
    #expect(agent.kind == "interactive")
    #expect(agent.startedAt == 1793094553199)
    #expect(agent.sessionId == "abc")
    #expect(agent.name == "spm-ecosystem-prs")
    #expect(agent.status == "idle")
    #expect(agent.id == nil)
    #expect(agent.state == nil)
}

@Test func decodesBackground() throws {
    let agents = try Agent.decode(Data(#"[{"id":"bef2ee91","cwd":"/some/path","kind":"background","startedAt":1783325721248,"sessionId":"abc","name":"SPM update with hook","state":"blocked"}]"#.utf8))
    let agent = try #require(agents.first)
    #expect(agent.id == "bef2ee91")
    #expect(agent.cwd == "/some/path")
    #expect(agent.kind == "background")
    #expect(agent.startedAt == 1783325721248)
    #expect(agent.sessionId == "abc")
    #expect(agent.name == "SPM update with hook")
    #expect(agent.state == "blocked")
    #expect(agent.pid == nil)
    #expect(agent.status == nil)
}

@Test func missingFields() throws {
    let agent = try #require(Agent.decode(Data("[{}]".utf8)).first)
    #expect(agent.id == nil)
    #expect(agent.pid == nil)
    #expect(agent.cwd == nil)
    #expect(agent.kind == nil)
    #expect(agent.startedAt == nil)
    #expect(agent.sessionId == nil)
    #expect(agent.name == nil)
    #expect(agent.status == nil)
    #expect(agent.state == nil)
}

@Test func wrongTypesDoNotBreakArray() throws {
    let agents = try Agent.decode(Data(#"[{"pid":8108,"name":"first"},{"pid":"abc","name":42},{"name":"last","status":"idle"}]"#.utf8))
    #expect(agents.count == 3)
    #expect(agents[1].name == nil)
    #expect(agents[1].pid == nil)
    #expect(agents[1].displayName == "unnamed")
    #expect(agents.contains { $0.name == "first" && $0.pid == 8108 })
    #expect(agents.contains { $0.name == "last" && $0.status == "idle" })
}

@Test func mapping() {
    for raw in ["blocked", "waiting", "needs_input", "awaiting_input", "permission", "input"] {
        #expect(AgentStatus(rawValue: raw).activity == .waiting)
        #expect(AgentStatus(rawValue: raw).unknownRawValue == nil)
    }
    for raw in ["busy", "running", "working", "active", "thinking", "BUSY"] {
        #expect(AgentStatus(rawValue: raw).activity == .working)
        #expect(AgentStatus(rawValue: raw).unknownRawValue == nil)
    }
    for raw in ["idle", "done", "completed", "finished", "stopped"] {
        #expect(AgentStatus(rawValue: raw).activity == .idle)
        #expect(AgentStatus(rawValue: raw).unknownRawValue == nil)
    }
    #expect(AgentStatus(rawValue: "foo").activity == .working)
    #expect(AgentStatus(rawValue: "foo").unknownRawValue == "foo")
    #expect(AgentStatus(rawValue: nil).activity == .working)
    #expect(AgentStatus(rawValue: nil).unknownRawValue == nil)
}

@Test func stateWins() throws {
    let agents = try Agent.decode(Data(#"[{"state":"BLOCKED","status":"idle"}]"#.utf8))
    #expect(agents.first?.resolvedStatus.activity == .waiting)
}

@Test func aggregation() {
    #expect(Activity.aggregate([]) == .idle)
    #expect(Activity.aggregate([.idle]) == .idle)
    #expect(Activity.aggregate([.idle, .working]) == .working)
    #expect(Activity.aggregate([.idle, .working, .waiting]) == .waiting)
}

@Test func sorting() throws {
    let agents = try Agent.decode(Data(#"[{"name":"Zulu","status":"idle"},{"name":"beta","status":"busy"},{"name":"zeta","state":"blocked"},{"name":"Alpha","status":"busy"},{"name":"alpha","state":"blocked"},{"name":"Beta","status":"idle"}]"#.utf8))
    #expect(Agent.sorted(agents).map(\.displayName) == ["alpha", "zeta", "Alpha", "beta", "Beta", "Zulu"])
}

@Test func processTimeout() throws {
    let start = Date()
    do {
        _ = try ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-ic", "sleep 60; true"], timeout: 1)
        Issue.record("Expected a timeout")
    } catch {
        #expect(error.localizedDescription.contains("timed out"))
    }
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func processOutput() throws {
    let output = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], timeout: 1)
    #expect(String(decoding: output, as: UTF8.self) == "hi\n")
}

@Test func processExitStatus() {
    do {
        _ = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], timeout: 1)
        Issue.record("Expected a non-zero exit error")
    } catch {
        #expect(error.localizedDescription.contains("exit 3"))
    }
}

@Test func binaryLookupOrder() throws {
    var checked: [String] = []
    var shellCalls = 0
    let candidate = try BinaryResolver.resolve(override: "/override", candidates: ["/first", "/second"], isExecutable: {
        checked.append($0)
        return $0 == "/second"
    }, shellLookup: {
        shellCalls += 1
        return "/shell"
    })
    #expect(candidate == "/second")
    #expect(checked == ["/override", "/first", "/second"])
    #expect(shellCalls == 0)
    checked = []
    let shell = try BinaryResolver.resolve(override: "/override", candidates: ["/first"], isExecutable: {
        checked.append($0)
        return $0 == "/shell"
    }, shellLookup: {
        shellCalls += 1
        return "/shell"
    })
    #expect(shell == "/shell")
    #expect(checked == ["/override", "/first", "/shell"])
    #expect(shellCalls == 1)
    let override = try BinaryResolver.resolve(override: "/override", candidates: ["/first"], isExecutable: { _ in true }, shellLookup: {
        Issue.record("Shell should not run for executable override")
        return "/shell"
    })
    #expect(override == "/override")
}

@Test func failedOverrideMessage() {
    do {
        _ = try BinaryResolver.resolve(override: "/invalid", candidates: [], isExecutable: { _ in false }, shellLookup: {
            throw CommandError(message: "exit 1")
        })
        Issue.record("Expected lookup failure")
    } catch {
        #expect(error.localizedDescription.contains("CLAUDE_BIN"))
        #expect(error.localizedDescription.contains("/invalid"))
    }
}

@Test func displayNameFallbackOrder() throws {
    let agents = try Agent.decode(Data(#"[{"name":"named","cwd":"/a/project","sessionId":"session"},{"name":"","cwd":"/a/project","sessionId":"session"},{"cwd":"","sessionId":"session"},{"sessionId":""},{}]"#.utf8))
    #expect(agents.map(\.displayName) == ["named", "project", "session", "unnamed", "unnamed"])
}

@Test func menuLabels() throws {
    let agents = try Agent.decode(Data(#"[{"name":"A","status":"blocked"},{"name":"B","status":"busy"},{"name":"C","status":"idle"},{"name":"D","status":"foo"}]"#.utf8))
    #expect(agents.map(\.menuLabel) == ["A — waiting", "B — working", "C — idle", "D — working (unknown: foo)"])
}

@Test func skipsNonObjectEntries() throws {
    let agents = try Agent.decode(Data(#"[{"name":"first"},5,null,"s",{"name":"last"}]"#.utf8))
    #expect(agents.map(\.displayName) == ["first", "last"])
}

@Test func rejectsNonArrayJSON() {
    #expect(throws: DecodingError.self) {
        try Agent.decode(Data(#"{"a":1}"#.utf8))
    }
}

@Test func sortingByLastActivityWithinStatus() throws {
    var agents = try Agent.decode(Data(#"[{"name":"old","status":"idle"},{"name":"none","status":"idle"},{"name":"new","status":"idle"},{"name":"waiting","state":"blocked"}]"#.utf8))
    agents[0].lastActivity = Date(timeIntervalSince1970: 100)
    agents[2].lastActivity = Date(timeIntervalSince1970: 200)
    #expect(Agent.sorted(agents).map(\.displayName) == ["waiting", "new", "old", "none"])
}
