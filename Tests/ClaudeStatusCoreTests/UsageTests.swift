import Foundation
import Testing
@testable import ClaudeStatusCore

private func decode(_ json: String) throws -> Usage {
    try #require(Usage.decode(Data(json.utf8)))
}

@Test func usageGaugesShowUseTimeAndReset() throws {
    let usage = try decode(#"{"five_hour":{"used_percentage":24.4,"resets_at":18000},"seven_day":{"used_percentage":26,"resets_at":604800},"spend_limit":{"used_usd":1}}"#)
    let gauges = usage.gauges(now: Date(timeIntervalSince1970: 18000 - 94 * 60))
    #expect(gauges.map(\.name) == ["Session", "Week"])
    #expect(gauges[0].used == 0.244)
    #expect(abs(gauges[0].elapsed! - (300 - 94) / 300.0) < 0.0001)
    #expect(gauges[0].detail == "24% · resets in 1h 34m")
    #expect(gauges[1].detail == "26% · resets in 6d 20h")
}

@Test func usageGaugeAfterResetHasNoUse() throws {
    let usage = try decode(#"{"five_hour":{"used_percentage":90,"resets_at":1000},"seven_day":{"used_percentage":40,"resets_at":1300}}"#)
    let gauges = usage.gauges(now: Date(timeIntervalSince1970: 1000))
    #expect(gauges[0].used == nil)
    #expect(gauges[0].elapsed == nil)
    #expect(gauges[0].detail == "reset")
    #expect(gauges[1].detail == "40% · resets in 5m")
}

@Test func usageGaugesSkipMissingWindows() throws {
    let gauges = try decode(#"{"seven_day":{"used_percentage":140}}"#).gauges(now: Date())
    #expect(gauges.map(\.name) == ["Week"])
    #expect(gauges[0].used == 1)
    #expect(gauges[0].detail == "140%")
    #expect(Usage.decode(Data("not json".utf8)) == nil)
    #expect(try decode("{}").gauges(now: Date()).isEmpty)
}

@Test func weekDaysFollowTheWindow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    // Window ends Thursday 2026-11-05 09:00 Oslo time, so it starts Thursday 2026-10-29 09:00.
    let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9)))
    let days = Usage.weekDays(endingAt: end, calendar: calendar)
    #expect(days.map(\.symbol) == ["T", "F", "S", "S", "M", "T", "W"])
    #expect(days.map(\.isWeekend) == [false, false, true, true, false, false, false])
}
