import Foundation
import Testing
@testable import ClaudeStatusCore

private func agents() throws -> [Agent] {
    var agents = try Agent.decode(Data(#"[{"pid":8108,"cwd":"/work/app","kind":"interactive","startedAt":1793094553199,"sessionId":"abc-1","name":"fix <login>","status":"busy"},{"pid":9,"cwd":"/work/other","sessionId":"def-2","name":"other","status":"idle"}]"#.utf8))
    agents[0].runningSubagents = 2
    agents[0].shellCommands = 1
    return agents
}

private func snapshot() throws -> WebSnapshot {
    WebSnapshot(agents: try agents(), summaries: ["abc-1": "Tests pass & PR open"], hosts: ["abc-1": "cmux"], usages: [], updated: Date(timeIntervalSince1970: 0))
}

@Test func webListLinksEachAgentAndEscapesText() throws {
    let html = WebPage.list(try snapshot(), now: Date(timeIntervalSince1970: 60))
    #expect(html.contains(#"href="/agent/abc-1""#))
    #expect(html.contains(#"href="/agent/def-2""#))
    #expect(html.contains("fix &lt;login&gt;"))
    #expect(!html.contains("fix <login>"))
    #expect(html.contains("Tests pass &amp; PR open"))
}

@Test func webDetailShowsStateLedgerAndLastText() throws {
    let html = try #require(WebPage.detail(try snapshot(), id: "abc-1", ledger: "# Task ledger — fix\n## Next step\nShip", lastText: "Done <ok>", now: Date(timeIntervalSince1970: 60), stopToken: "t"))
    #expect(html.contains("working"))
    #expect(html.contains("/work/app"))
    #expect(html.contains("2 sub-agents"))
    #expect(html.contains("1 shell command"))
    #expect(html.contains("cmux"))
    #expect(html.contains("## Next step"))
    #expect(html.contains("Done &lt;ok&gt;"))
}

@Test func webDetailIsNilForAnUnknownAgent() throws {
    #expect(WebPage.detail(try snapshot(), id: "nope", ledger: nil, lastText: nil, now: Date(), stopToken: "t") == nil)
}

@Test func webRequestReadsMethodPathAndForm() throws {
    let get = try #require(WebPage.Request("GET /agent/abc-1?x=1 HTTP/1.1\r\nHost: x\r\n\r\n"))
    #expect(get.method == "GET")
    #expect(get.path == "/agent/abc-1")
    let post = try #require(WebPage.Request("POST /agent/abc-1/stop HTTP/1.1\r\nContent-Length: 13\r\n\r\ntoken=a%2Bb&x"))
    #expect(post.method == "POST")
    #expect(post.form["token"] == "a+b")
    #expect(WebPage.Request("garbage") == nil)
}

@Test func webRequestKnowsWhenTheBodyIsIncomplete() {
    #expect(WebPage.Request.isComplete("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
    #expect(!WebPage.Request.isComplete("GET / HTTP/1.1\r\nHost: x\r\n"))
    #expect(!WebPage.Request.isComplete("POST /s HTTP/1.1\r\nContent-Length: 10\r\n\r\ntoken"))
    #expect(WebPage.Request.isComplete("POST /s HTTP/1.1\r\ncontent-length: 5\r\n\r\ntoken"))
}

@Test func webDetailHasAStopFormWithTheToken() throws {
    let html = try #require(WebPage.detail(try snapshot(), id: "abc-1", ledger: nil, lastText: nil, now: Date(), stopToken: "t0k"))
    #expect(html.contains(#"action="/agent/abc-1/stop""#))
    #expect(html.contains(#"method="post""#))
    #expect(html.contains(#"value="t0k""#))
}

@Test func stopUsesClaudeStopForBackgroundAndASignalOtherwise() throws {
    let background = try #require(Agent.decode(Data(#"[{"id":"bef2ee91","kind":"background","sessionId":"s","state":"blocked"}]"#.utf8)).first)
    #expect(WebPage.stopAction(for: background) == .command(["stop", "bef2ee91"]))
    #expect(WebPage.stopAction(for: try agents()[0]) == .signal(8108))
    let unknown = try #require(Agent.decode(Data(#"[{"sessionId":"s","status":"idle"}]"#.utf8)).first)
    #expect(WebPage.stopAction(for: unknown) == nil)
}

@Test func tailscaleAddressIsInTheCarrierGradeRange() {
    #expect(WebPage.isTailscale("100.115.66.60"))
    #expect(WebPage.isTailscale("100.64.0.1"))
    #expect(!WebPage.isTailscale("100.128.0.1"))
    #expect(!WebPage.isTailscale("192.168.1.2"))
}
