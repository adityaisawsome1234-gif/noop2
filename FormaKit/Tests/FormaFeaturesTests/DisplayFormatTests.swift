import Foundation
import Testing
import FormaCore
@testable import FormaFeatures

@Suite struct DisplayFormatTests {
    @Test func numbers() {
        #expect(DisplayFormat.number(52.04, digits: 1) == "52.0")
        #expect(DisplayFormat.number(52.05, digits: 1) == "52.1")
        #expect(DisplayFormat.number(-1.25, digits: 2) == "\u{2212}1.25")
        #expect(DisplayFormat.number(0.04, digits: 1) == "0.0")
        #expect(DisplayFormat.number(-0.04, digits: 1) == "0.0")
        #expect(DisplayFormat.number(7.0, digits: 0) == "7")
        #expect(DisplayFormat.number(1.005, digits: 3) == "1.005")
        #expect(DisplayFormat.number(.nan, digits: 1) == "—")
        #expect(DisplayFormat.signed(0.44, digits: 1) == "+0.4")
        #expect(DisplayFormat.signed(-1.2, digits: 1) == "\u{2212}1.2")
        #expect(DisplayFormat.signed(0.01, digits: 1) == "0.0")
        #expect(DisplayFormat.percent(0.856) == "86%")
    }

    @Test func times() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let t: EpochMillis = 1_762_560_000_000 + 23 * 3_600_000 + 5 * 60_000  // 2025-11-08 23:05 UTC
        #expect(DisplayFormat.clock(t, calendar: cal) == "23:05")
        #expect(DisplayFormat.range(TimeRange(start: t, end: t + 7 * 3_600_000 + 45 * 60_000), calendar: cal) == "23:05\u{2013}06:50")
        #expect(DisplayFormat.duration(millis: 7 * 3_600_000 + 45 * 60_000) == "7 h 45 min")
        #expect(DisplayFormat.duration(millis: 45 * 60_000) == "45 min")
        #expect(DisplayFormat.duration(millis: 2 * 3_600_000) == "2 h")
        #expect(DisplayFormat.timer(millis: 3_909_000) == "1:05:09")
        #expect(DisplayFormat.timer(millis: 309_000) == "5:09")
        #expect(DisplayFormat.dayLabel(LocalDay(year: 2025, month: 11, day: 8), calendar: cal) == "Sat 8 Nov")
    }
}
