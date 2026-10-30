import Darwin
import Foundation
import Testing
@testable import ClaudeStatusCore

private func agents(_ json: String) throws -> [Agent] {
    try Agent.decode(Data(json.utf8))
}

private func roster(_ json: String) throws -> Roster {
    try JSONDecoder().decode(Roster.self, from: Data(json.utf8))
}

private let workerJSON = #"{"workers":{"cd53050e":{"pid":44961,"procStart":"Wed Sep 23 17:41:55 2026"}}}"#
private let backgroundJSON = #"[{"kind":"background","id":"cd53050e","state":"blocked"}]"#

@Test func deadInteractiveIsDropped() throws {
    let input = try agents(#"[{"pid":123,"kind":"interactive"}]"#)
    let result = Agent.live(input, roster: nil, isAlive: { pid, starts in
        #expect(pid == 123)
        #expect(starts.isEmpty)
        return false
    })
    #expect(result.isEmpty)
}

@Test func liveInteractiveIsKept() throws {
    let input = try agents(#"[{"pid":123,"kind":"interactive"}]"#)
    let result = Agent.live(input, roster: nil, isAlive: { _, _ in true })
    #expect(result.count == 1)
}

@Test func matchingBackgroundIsKept() throws {
    let input = try agents(backgroundJSON)
    let data = try roster(workerJSON)
    let start = Date(timeIntervalSince1970: 1790185315)
    let result = Agent.live(input, roster: data, isAlive: { pid, starts in
        #expect(pid == 44961)
        #expect(!starts.isEmpty)
        return ProcessLiveness.matches(start: start, candidates: starts)
    })
    #expect(result.count == 1)
}

@Test func deadBackgroundIsDropped() throws {
    let input = try agents(backgroundJSON)
    let data = try roster(workerJSON)
    let result = Agent.live(input, roster: data, isAlive: { _, _ in false })
    #expect(result.isEmpty)
}

@Test func backgroundAbsentFromRosterIsDropped() throws {
    let input = try agents(#"[{"kind":"background","id":"bef2ee91"}]"#)
    let data = try roster(workerJSON)
    let result = Agent.live(input, roster: data, isAlive: { _, _ in
        Issue.record("Absent worker must not be checked")
        return true
    })
    #expect(result.isEmpty)
}

@Test func unknownRosterKeepsBackground() throws {
    let input = try agents(backgroundJSON)
    let result = Agent.live(input, roster: nil, isAlive: { _, _ in false })
    #expect(result.count == 1)
}

@Test func parsesProcStart() {
    let starts = ProcessStart.candidates("Wed Sep 23 17:41:55 2026", localTimeZone: TimeZone(secondsFromGMT: 7200)!)
    #expect(starts.count == 2)
    #expect(starts.contains(Date(timeIntervalSince1970: 1790185315)))
    #expect(starts.contains(Date(timeIntervalSince1970: 1790178115)))
}

@Test func parsesProcStartWithDoubleSpace() {
    let starts = ProcessStart.candidates("Fri Oct  9 07:05:01 2026", localTimeZone: TimeZone(secondsFromGMT: 0)!)
    #expect(starts.contains(Date(timeIntervalSince1970: 1791529501)))
}

@Test func mismatchedBackgroundStartIsDropped() throws {
    let input = try agents(backgroundJSON)
    let data = try roster(workerJSON)
    let result = Agent.live(input, roster: data, isAlive: { _, starts in
        ProcessLiveness.matches(start: Date(timeIntervalSince1970: 0), candidates: starts)
    })
    #expect(result.isEmpty)
}

@Test func missingProcStartUsesPIDOnly() throws {
    let input = try agents(backgroundJSON)
    let data = try roster(#"{"workers":{"cd53050e":{"pid":44961}}}"#)
    let result = Agent.live(input, roster: data, isAlive: { _, starts in
        #expect(starts.isEmpty)
        return true
    })
    #expect(result.count == 1)
    let deadResult = Agent.live(input, roster: data, isAlive: { _, _ in false })
    #expect(deadResult.isEmpty)
}

@Test func invalidProcStartUsesPIDOnly() throws {
    let input = try agents(backgroundJSON)
    let data = try roster(#"{"workers":{"cd53050e":{"pid":44961,"procStart":"invalid"}}}"#)
    let result = Agent.live(input, roster: data, isAlive: { _, starts in
        #expect(starts.isEmpty)
        return true
    })
    #expect(result.count == 1)
}

@Test func rosterDecodesValidWorkersLeniently() throws {
    let data = try roster(#"{"proto":1,"supervisorPid":4862,"updatedAt":1791528824220,"extra":true,"workers":{"cd53050e":{"pid":44961,"procStart":"Wed Sep 23 17:41:55 2026","sessionId":"cd53050e-...","rendezvousSock":"...","ptySock":"...","cliVersion":"..."},"bad":{"pid":"x"}}}"#)
    #expect(data.workers["cd53050e"]?.pid == 44961)
    #expect(data.workers["cd53050e"]?.procStart == "Wed Sep 23 17:41:55 2026")
    #expect(data.workers["bad"] == nil)
    #expect(data.workers.count == 1)
    let input = try agents(#"[{"kind":"background","id":"bad"}]"#)
    let result = Agent.live(input, roster: data, isAlive: { _, _ in
        Issue.record("Undecodable worker must not be checked")
        return false
    })
    #expect(result.count == 1)
}

@Test func realProcessIsAliveWithRealStartTime() throws {
    let pid = getpid()
    let start = try #require(ProcessLiveness.startTime(pid: pid))
    #expect(ProcessLiveness.isAlive(pid: pid, starts: [start]))
}

@Test func agentWithoutPIDOrBackgroundIDIsKept() throws {
    let input = try agents(#"[{}, {"kind":"background"}, {"id":"other","kind":"unknown"}]"#)
    let data = try roster(#"{"workers":{}}"#)
    let result = Agent.live(input, roster: data, isAlive: { _, _ in false })
    #expect(result.count == 3)
}

@Test func startMatchingAllowsTwoSecondsAndEitherTimezone() {
    let starts = ProcessStart.candidates("Wed Sep 23 17:41:55 2026", localTimeZone: TimeZone(secondsFromGMT: 7200)!)
    for start in starts {
        #expect(ProcessLiveness.matches(start: start.addingTimeInterval(2), candidates: starts))
        #expect(ProcessLiveness.matches(start: start.addingTimeInterval(-2), candidates: starts))
        #expect(!ProcessLiveness.matches(start: start.addingTimeInterval(3), candidates: starts))
    }
}

@Test func observedStaleBackgroundAgentsAreExcludedFromCounts() throws {
    let input = try agents(#"[{"id":"bef2ee91","kind":"background","state":"blocked"},{"id":"cd53050e","kind":"background","state":"blocked"}]"#)
    let data = try roster(workerJSON)
    var checked: [Int32] = []
    let live = Agent.live(input, roster: data, isAlive: { pid, _ in
        checked.append(pid)
        return false
    })
    #expect(checked == [44961])
    #expect(live.isEmpty)
    let activities = live.map { $0.resolvedStatus.activity }
    #expect(Activity.aggregate(activities) == .idle)
    #expect(activities.filter { $0 == .waiting }.count == 0)
}

@Test func undecodableRosterIsUnknown() {
    #expect((try? JSONDecoder().decode(Roster.self, from: Data(#"{"workers":42}"#.utf8))) == nil)
}
