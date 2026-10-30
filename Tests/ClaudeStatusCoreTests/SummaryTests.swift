import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func summaryStripsMarkdownAndWhitespace() {
    #expect(Summary.plainText("# Result\n- **Done** with `parser`\n* Next\n+ More\n1. Ask\t now") == "Result Done with parser Next More Ask now")
}

@Test func summaryInputKeepsEnd() {
    #expect(Summary.input("abcdef", maxCharacters: 4) == "cdef")
    #expect(Summary.input("short", maxCharacters: 10) == "short")
    #expect(Summary.input("🙂abc", maxCharacters: 3) == "abc")
}

@Test func summaryWrapsAndCuts() {
    #expect(Summary.twoLines("one two three four", maxCharsPerLine: 9) == "one two\nthree…")
    #expect(Summary.twoLines("one two three four five", maxCharsPerLine: 9) == "one two\nthree…")
    #expect(Summary.twoLines("abcdefghijklmnop", maxCharsPerLine: 5) == "abcde\nfghi…")
    #expect(Summary.twoLines("  one\n two  ", maxCharsPerLine: 20) == "one two")
    #expect(Summary.twoLines("", maxCharsPerLine: 60) == "")
}

@Test func summaryHardCutsLongWord() {
    #expect(Summary.twoLines("abcdefghijklmnop", maxCharsPerLine: 5) == "abcde\nfghi…")
}

private actor SummaryCalls {
    var count = 0
    func summarize(_ text: String) -> String {
        count += 1
        return "Summary: \(text)"
    }
}

@Test func summaryCacheSkipsUnchangedText() async {
    let calls = SummaryCalls()
    let cache = SummaryCache { text in await calls.summarize(text) }
    #expect(await cache.summary(sessionId: "a", text: "first") == "Summary: first")
    #expect(await cache.summary(sessionId: "a", text: "first") == "Summary: first")
    #expect(await calls.count == 1)
    #expect(await cache.summary(sessionId: "a", text: "changed") == "Summary: changed")
    #expect(await cache.summary(sessionId: "b", text: "changed") == "Summary: changed")
    #expect(await calls.count == 3)
}

@Test func summaryCacheFallsBackOnFailure() async {
    let cache = SummaryCache { _ in throw CocoaError(.fileReadUnknown) }
    #expect(await cache.summary(sessionId: "a", text: "# **Done**\n- Tests passed") == "Done Tests passed")
}

private actor RetrySummaryCalls {
    var count = 0
    func summarize(_ text: String) throws -> String {
        count += 1
        if count == 1 { throw CocoaError(.fileReadUnknown) }
        return "Model summary"
    }
}

@Test func summaryCacheRetriesFallbackAfterFiveMinutes() async {
    let clock = TestClock()
    let calls = RetrySummaryCalls()
    let cache = SummaryCache(now: { clock.now }) { text in try await calls.summarize(text) }
    #expect(await cache.summary(sessionId: "a", text: "# Fallback") == "Fallback")
    clock.advance(60)
    #expect(await cache.summary(sessionId: "a", text: "# Fallback") == "Fallback")
    #expect(await calls.count == 1)
    clock.advance(300)
    #expect(await cache.summary(sessionId: "a", text: "# Fallback") == "Model summary")
    #expect(await calls.count == 2)
}

@Test func summaryCacheKeepsModelSummaryAndPrunesDepartedSessions() async {
    let clock = TestClock()
    let calls = SummaryCalls()
    let cache = SummaryCache(now: { clock.now }) { text in await calls.summarize(text) }
    #expect(await cache.summary(sessionId: "a", text: "text") == "Summary: text")
    clock.advance(600)
    #expect(await cache.summary(sessionId: "a", text: "text") == "Summary: text")
    #expect(await calls.count == 1)
    _ = await cache.summary(sessionId: "b", text: "text")
    await cache.prune(sessionIds: ["a"])
    _ = await cache.summary(sessionId: "a", text: "text")
    #expect(await calls.count == 2)
    _ = await cache.summary(sessionId: "b", text: "text")
    #expect(await calls.count == 3)
}

@Test func summaryPreservesHashInsideWords() {
    #expect(Summary.plainText("# Heading\nUse C#") == "Heading Use C#")
}

@Test func summaryStripsMarkdownLinks() {
    #expect(Summary.plainText("Read [the docs](https://example.com/docs) now") == "Read the docs now")
    #expect(Summary.plainText("Read [docs](https://example.com/foo(bar)/guide) now") == "Read docs now")
}

@Test func summaryDropsExactBoundaryWordForEllipsis() {
    let result = Summary.twoLines("first one two abc def more", maxCharsPerLine: 11)
    #expect(result == "first one\ntwo abc…")
    #expect(result.split(separator: "\n").allSatisfy { $0.count <= 11 })
}
