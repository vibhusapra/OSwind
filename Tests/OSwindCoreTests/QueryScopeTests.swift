import XCTest
@testable import OSwindCore

final class QueryScopeTests: XCTestCase {
    let zone = TimeZone(identifier:"America/Los_Angeles")!
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from:text)! }
    func resolve(_ query: String, now: String = "2026-10-23T17:30:00Z", filter: SearchFilter = SearchFilter(), literal: Bool = false) throws -> QueryResolution {
        var input = filter; input.query = query
        return try QueryScopeResolver.resolve(input,now:date(now),timeZone:zone,interpret:!literal)
    }
    func testRelativeDayAndScopeOnlyQueryResolveToExclusiveCalendarBounds() throws {
        let result = try resolve("What did I ship yesterday?")
        XCTAssertEqual(result.filter.start,date("2026-10-22T07:00:00Z")); XCTAssertEqual(result.filter.end,date("2026-10-23T07:00:00Z"))
        XCTAssertEqual(result.filter.query,"What did I ship ?"); XCTAssertEqual(result.clauses.count,1)
        XCTAssertEqual(try resolve("yesterday?").filter.query,"")
        XCTAssertEqual(try resolve("on:today").filter.end,date("2026-10-24T07:00:00Z"))
    }
    func testDSTCalendarDaysHave23And25Hours() throws {
        let spring = try resolve("today",now:"2026-03-08T19:00:00Z"), autumn = try resolve("today",now:"2026-11-01T20:00:00Z")
        XCTAssertEqual(spring.filter.end!.timeIntervalSince(spring.filter.start!),23*3600)
        XCTAssertEqual(autumn.filter.end!.timeIntervalSince(autumn.filter.start!),25*3600)
        XCTAssertEqual(spring.filter.start,date("2026-03-08T08:00:00Z")); XCTAssertEqual(autumn.filter.end,date("2026-11-02T08:00:00Z"))
    }
    func testMorningAfternoonAndNightUseWallClockAcrossDST() throws {
        let morning = try resolve("this morning",now:"2026-03-08T19:00:00Z")
        XCTAssertEqual(morning.filter.end,date("2026-03-08T19:00:00Z")); XCTAssertEqual(morning.filter.end!.timeIntervalSince(morning.filter.start!),11*3600)
        let afternoon = try resolve("this afternoon",now:"2026-11-01T23:00:00Z")
        XCTAssertEqual(afternoon.filter.start,date("2026-11-01T20:00:00Z")); XCTAssertEqual(afternoon.filter.end,date("2026-11-02T02:00:00Z"))
        let night = try resolve("last night",now:"2026-11-01T18:00:00Z")
        XCTAssertEqual(night.filter.start,date("2026-11-01T01:00:00Z")); XCTAssertEqual(night.filter.end,date("2026-11-01T14:00:00Z"))
    }
    func testWeeksStartMondayAndMonthsCrossYearBoundaries() throws {
        let week = try resolve("last week")
        XCTAssertEqual(week.filter.start,date("2026-10-12T07:00:00Z")); XCTAssertEqual(week.filter.end,date("2026-10-19T07:00:00Z"))
        let month = try resolve("last month",now:"2026-01-03T12:00:00Z")
        XCTAssertEqual(month.filter.start,date("2025-12-01T08:00:00Z")); XCTAssertEqual(month.filter.end,date("2026-01-01T08:00:00Z"))
    }
    func testRollingWindowCountsAndBounds() throws {
        let hours = try resolve("past 24 hours",now:"2026-03-08T19:00:00Z")
        XCTAssertEqual(hours.filter.end!.timeIntervalSince(hours.filter.start!),24*3600)
        let days = try resolve("last 7 days")
        XCTAssertEqual(days.filter.start,date("2026-10-16T17:30:00Z")); XCTAssertEqual(days.filter.end,date("2026-10-23T17:30:00Z"))
        XCTAssertThrowsError(try resolve("past 0 days")); XCTAssertThrowsError(try resolve("last 9999 months"))
    }
    func testQuotedAppTagKindAndSavedOperators() throws {
        let result = try resolve(#"deadline app:"Google Chrome" kind:audio tag:"project north" is:favorite yesterday"#)
        XCTAssertEqual(result.filter.app,"Google Chrome"); XCTAssertEqual(result.filter.kind,.audio); XCTAssertEqual(result.filter.tag,"project north")
        XCTAssertTrue(result.filter.favoritesOnly); XCTAssertEqual(result.filter.query,"deadline"); XCTAssertEqual(result.clauses.count,5)
        let escaped = try resolve(#"app:"A \"quoted\" app" today"#)
        XCTAssertEqual(escaped.filter.app,#"A "quoted" app"#)
    }
    func testSmartQuotesAndSentencePunctuationPreserveFilterValues() throws {
        let result = try resolve("Comet app:“Google Chrome”? yesterday!")
        XCTAssertEqual(result.filter.app,"Google Chrome"); XCTAssertEqual(result.filter.start,date("2026-10-22T07:00:00Z"))
        XCTAssertTrue(try resolve("“yesterday app:Mail”").clauses.isEmpty)
        XCTAssertEqual(try resolve(#"app:"Why?""#).filter.app,"Why?")
        XCTAssertEqual(try resolve("tag:work, kind:note.").filter.tag,"work")
    }
    func testISOInstantsAndLocalDateBoundsIntersectControls() throws {
        let result = try resolve("budget since:2026-10-20 until:2026-10-24T00:00:00Z yesterday",filter:SearchFilter(start:date("2026-10-22T12:00:00Z")))
        XCTAssertEqual(result.filter.start,date("2026-10-22T12:00:00Z")); XCTAssertEqual(result.filter.end,date("2026-10-23T07:00:00Z"))
        XCTAssertEqual(try resolve("since:2026-10-22T12:30:00.125Z").filter.start!.timeIntervalSince1970,date("2026-10-22T12:30:00Z").timeIntervalSince1970+0.125,accuracy:0.00001)
    }
    func testInvalidDatesAndConflictingFiltersNeverBecomeBroadQueries() throws {
        for text in ["on:2026-02-29","on:2026-02-30","on:2026-13-01","since:2026-02-30T12:00:00Z","until:tomorrow","kind:unknown","is:public","app:",#"app:"unclosed"#,"app:A app:B","kind:audio kind:note","tag:a tag:b"] { XCTAssertThrowsError(try resolve(text),text) }
        XCTAssertThrowsError(try resolve("yesterday",filter:SearchFilter(start:date("2026-10-23T07:00:00Z"))))
        XCTAssertThrowsError(try resolve("app:A",filter:SearchFilter(app:"B")))
        XCTAssertNotNil(try resolve("on:2024-02-29").filter.start)
    }
    func testQuotedWordsURLsCodeAndPossessivesRemainText() throws {
        for text in [#""yesterday" "app:Mail""#,"today.swift report_yesterday Documents/yesterday/todo https://example.com/today","yesterday’s proposal","git:blame","today-report","todays yesterdayish"] {
            let result = try resolve(text)
            XCTAssertTrue(result.clauses.isEmpty,text); XCTAssertEqual(result.filter.query,text)
        }
        let literal = try resolve("today app:Mail",literal:true)
        XCTAssertNil(literal.filter.start); XCTAssertNil(literal.filter.app); XCTAssertEqual(literal.filter.query,"today app:Mail")
    }
    func testUnicodeClauseRangesRemoveOnlyTheirOriginalText() throws {
        let result = try resolve(#"🧠 réunion app:"Google  Chrome" yesterday"#)
        let time = try XCTUnwrap(result.clauses.first {$0.kind == "time"})
        XCTAssertEqual(result.removing(time),#"🧠 réunion app:"Google  Chrome""#)
        let app = try XCTUnwrap(result.clauses.first {$0.kind == "app"})
        XCTAssertTrue(result.removing(app).hasSuffix("yesterday")); XCTAssertTrue(result.removing(app).hasPrefix("🧠 réunion"))
    }
}
