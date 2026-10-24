import XCTest
import CSQLite
@testable import OSwindCore

private final class ActivitySQLGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"owned calendar SQL prepare entered")
    private let condition=NSCondition()
    private var released=false,didEnter=false
    func wait() {
        condition.lock();defer {condition.unlock()};guard !didEnter else {return};didEnter=true;entered.fulfill()
        let deadline=Date().addingTimeInterval(10)
        while !released {if !condition.wait(until:deadline) {break}}
    }
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}
final class ActivityCalendarTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-calendar-owned-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    func instant(_ value:String) throws -> Date {try QueryScopeResolver.instant(value)}
    func request(_ month:String="2024-03",zone:String="America/New_York",day:String?=nil,filter:SearchFilter=SearchFilter()) throws -> ActivityCalendarRequest {.init(month:month,timeZone:try XCTUnwrap(TimeZone(identifier:zone)),selectedDay:day,filter:filter)}
    func add(_ id:String,_ time:String,app:String="Notes",kind:MemoryKind = .note,favorite:Bool=false,tags:[String]=[]) throws {
        try store.insert(Memory(id:id,timestamp:try instant(time),kind:kind,app:app,title:"Owned",text:"Owned source",favorite:favorite,tags:tags))
    }
    func testEmptyLeapMonthIncludesZerosAndLocalizedWeekStart() throws {
        var value=try request("2024-02");let sunday=try store.activityCalendar(value)
        XCTAssertEqual(sunday.days.count,29);XCTAssertEqual(sunday.leadingEmptyDays,4);XCTAssertEqual(sunday.totalSources,0);XCTAssertTrue(sunday.days.allSatisfy(\.available));XCTAssertTrue(sunday.hours.isEmpty)
        value.firstWeekday=2;XCTAssertEqual(try store.activityCalendar(value).leadingEmptyDays,3)
    }
    func testSourceTimesUseInclusiveStartExclusiveEndAndFullCountsNotResultLimit() throws {
        try add("before","2024-02-29T23:59:59.999-05:00");try add("start","2024-03-01T00:00:00-05:00");try add("fraction","2024-03-01T00:00:00.125-05:00");try add("next","2024-03-02T00:00:00-05:00");try add("outside","2024-04-01T00:00:00-04:00")
        let result=try store.activityCalendar(request(day:"2024-03-01",filter:SearchFilter(limit:1)))
        XCTAssertEqual(result.totalSources,3);XCTAssertEqual(result.days[0].sources,2);XCTAssertEqual(result.days[1].sources,1);XCTAssertEqual(result.hours[0].sources,2);XCTAssertEqual(result.hours.reduce(0){$0+$1.sources},2)
    }
    func testSpringForwardAndFallBackHaveExactDisjointBuckets() throws {
        let spring=try store.activityCalendar(request(day:"2024-03-10")),fall=try store.activityCalendar(request("2024-11",day:"2024-11-03"))
        XCTAssertEqual(spring.hours.count,23);XCTAssertFalse(spring.hours.contains {$0.hour==2});XCTAssertEqual(fall.hours.count,25)
        let repeated=fall.hours.filter {$0.hour==1};XCTAssertEqual(repeated.count,2);XCTAssertEqual(Set(repeated.map(\.utcOffsetSeconds)),[-14400,-18000])
        for result in [spring,fall] {
            let day=try XCTUnwrap(result.days.first {$0.key==result.selectedDay});XCTAssertEqual(result.hours.first?.start,day.start);XCTAssertEqual(result.hours.last?.end,day.end)
            for pair in zip(result.hours,result.hours.dropFirst()) {XCTAssertEqual(pair.0.end,pair.1.start)}
        }
        try add("first-1","2024-11-03T01:30:00-04:00");try add("second-1","2024-11-03T01:30:00-05:00")
        let counted=try store.activityCalendar(request("2024-11",day:"2024-11-03"));XCTAssertEqual(counted.hours.filter {$0.hour==1}.map(\.sources),[1,1]);XCTAssertEqual(counted.totalSources,2)
    }
    func testHalfHourAndQuarterHourZonesPreserveRealBoundaries() throws {
        let lordHowe=try store.activityCalendar(request("2024-10",zone:"Australia/Lord_Howe",day:"2024-10-06"))
        XCTAssertEqual(lordHowe.hours.reduce(0){$0+$1.end.timeIntervalSince($1.start)},23.5*3600)
        for pair in zip(lordHowe.hours,lordHowe.hours.dropFirst()) {XCTAssertEqual(pair.0.end,pair.1.start)}
        XCTAssertTrue(lordHowe.hours.allSatisfy {$0.end>$0.start && $0.end.timeIntervalSince($0.start)<=3600})
        let kathmandu=try store.activityCalendar(request(zone:"Asia/Kathmandu",day:"2024-03-01"));XCTAssertEqual(kathmandu.hours.count,24);XCTAssertEqual(kathmandu.hours.first?.utcOffsetSeconds,20700);XCTAssertEqual(try kathmandu.hours.first.map {try ISOTime.string($0.start)},"2024-02-29T18:15:00Z")
    }
    func testSkippedCivilDateStaysUnavailableInsteadOfAliasingNextDay() throws {
        let value=try request("2011-12",zone:"Pacific/Apia"),result=try store.activityCalendar(value)
        XCTAssertEqual(result.days.count,31);XCTAssertFalse(result.days[29].available);XCTAssertEqual(result.days[29].key,"2011-12-30");XCTAssertTrue(result.days[30].available)
        var skipped=value;skipped.selectedDay="2011-12-30";XCTAssertThrowsError(try store.activityCalendar(skipped))
    }
    func testMetadataFiltersIntersectWithoutHydratingFullSources() throws {
        try add("match","2024-03-01T12:00:00-05:00",app:"Safari",favorite:true,tags:["release"]);try add("other-app","2024-03-01T12:00:00-05:00",app:"Notes",favorite:true,tags:["release"]);try add("other-tag","2024-03-02T12:00:00-05:00",app:"Safari",favorite:true);try add("other-save","2024-03-02T12:00:00-05:00",app:"Safari",tags:["release"])
        let scope=SearchFilter(app:"Safari",kind:.note,start:try instant("2024-03-01T00:00:00-05:00"),end:try instant("2024-03-02T00:00:00-05:00"),favoritesOnly:true,tag:"release")
        let result=try store.activityCalendar(request(filter:scope));XCTAssertEqual(result.totalSources,1);XCTAssertEqual(result.scope,ActivitySourceScope(scope))
    }
    func testRecordingLocalSpeakerUsesCanonicalLabelsAndCanBeRenamed() throws {
        var memory=Memory(id:"audio",timestamp:try instant("2024-03-01T12:00:00-05:00"),kind:.audio,app:"Audio",text:"Owned speech")
        memory.transcript=SpeechTranscript(text:memory.text,duration:1,segments:[TranscriptSegment(start:0,end:1,text:memory.text,speaker:"Maya Chen")],model:"fixture");try store.insert(memory)
        XCTAssertEqual(try store.activityCalendar(request(filter:SearchFilter(speaker:"MAYA CHEN"))).totalSources,1);XCTAssertEqual(try store.activityCalendar(request(filter:SearchFilter(speaker:"Maya"))).totalSources,0)
        _ = try store.renameAudioSpeaker(memory.id,from:"Maya Chen",to:"Alex",policy:PrivacyPolicy())
        XCTAssertEqual(try store.activityCalendar(request(filter:SearchFilter(speaker:"Maya Chen"))).totalSources,0);XCTAssertEqual(try store.activityCalendar(request(filter:SearchFilter(speaker:"Alex"))).totalSources,1)
    }
    func testUnfilteredAndAppCountsNeverReadTextPayloadOrEmbeddingColumns() throws {
        try add("owned","2024-03-01T12:00:00-05:00")
        _ = try store.withRoutineDatabase {db in
            sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",["text","payload","embedding","embedding_model"].contains(String(cString:column)) {return SQLITE_DENY};return SQLITE_OK
            },nil)
        }
        defer {_ = try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        XCTAssertEqual(try store.activityCalendar(request()).totalSources,1);XCTAssertEqual(try store.activityCalendar(request(filter:SearchFilter(app:"Notes"))).totalSources,1)
    }
    func testRevisionDetectsSameConnectionAndExternalWritesWithoutChangingOnReads() throws {
        let before=try store.activityCalendarRevision();_ = try store.activityCalendar(request());XCTAssertEqual(try store.activityCalendarRevision(),before)
        try add("own","2024-03-01T00:00:00-05:00");let own=try store.activityCalendarRevision();XCTAssertNotEqual(own.ownChanges,before.ownChanges)
        let external=try MemoryStore(root:root);try external.insert(Memory(id:"external",timestamp:try instant("2024-03-02T00:00:00-05:00"),text:"Owned external"));try external.close()
        let after=try store.activityCalendarRevision();XCTAssertNotEqual(after.externalVersion,own.externalVersion);XCTAssertEqual(after.ownChanges,own.ownChanges);XCTAssertEqual(try store.activityCalendar(request()).totalSources,2)
    }
    func testUpdateDeleteAndReopenCannotLeaveStaleBuckets() throws {
        try add("moved","2024-03-01T12:00:00-05:00");var memory=try XCTUnwrap(store.get("moved"));memory.timestamp=try instant("2024-03-02T12:00:00-05:00");try store.insert(memory)
        var value=try store.activityCalendar(request());XCTAssertEqual(value.days[0].sources,0);XCTAssertEqual(value.days[1].sources,1)
        try store.delete("moved");try store.close();store=try MemoryStore(root:root);value=try store.activityCalendar(request());XCTAssertEqual(value.totalSources,0)
    }
    func testInvalidMonthsDaysFiltersAndClosedStoreFailExplicitly() throws {
        for month in ["2024-2","2024-00","2024-13","2024-02-extra","0000-01","9999-12","２０２４-０２"] {XCTAssertThrowsError(try store.activityCalendar(request(month)))}
        for day in ["2024-02-30","2024-04-01","2024-03-01T00:00:00Z"] {XCTAssertThrowsError(try store.activityCalendar(request(day:day)))}
        XCTAssertThrowsError(try store.activityCalendar(request(filter:SearchFilter(query:"semantic words"))));XCTAssertThrowsError(try store.activityCalendar(request(filter:SearchFilter(start:Date(),end:.distantPast))))
        try store.close();XCTAssertThrowsError(try store.activityCalendar(request()));XCTAssertThrowsError(try store.activityCalendarRevision())
    }
    func testCountIsNotCappedAtSearchResultLimit() throws {
        try store.withRoutineDatabase {db in try db.transaction {for index in 0..<600 {try add("owned-\(index)","2024-03-01T12:00:00-05:00")}}}
        let result=try store.activityCalendar(request(day:"2024-03-01",filter:SearchFilter(limit:1)));XCTAssertEqual(result.totalSources,600);XCTAssertEqual(result.hours.reduce(0){$0+$1.sources},600)
    }
    func testExistingSchema20GainsCoveringIndexesWithoutChangingSources() throws {
        try add("owned","2024-03-01T12:00:00-05:00",kind:.screen,favorite:true,tags:["release"])
        let original=try store.get("owned")
        try store.withRoutineDatabase {db in
            for sql in ["DROP INDEX memories_kind_time","DROP INDEX memories_favorite_time"] {
                let statement=try db.statement(sql);defer {sqlite3_finalize(statement)};XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE)
            }
        }
        try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try store.get("owned"),original)
        try store.withRoutineDatabase {db in
            for (predicate,name) in [("kind='screen'","memories_kind_time"),("favorite=1","memories_favorite_time")] {
                let statement=try db.statement("EXPLAIN QUERY PLAN SELECT COUNT(timestamp) FROM memories WHERE timestamp>=0 AND timestamp<2000000000 AND "+predicate)
                defer {sqlite3_finalize(statement)};var plans=[String]()
                while sqlite3_step(statement)==SQLITE_ROW {plans.append(String(cString:sqlite3_column_text(statement,3)))}
                XCTAssertTrue(plans.contains {$0.contains(name)},plans.joined(separator:"; "))
            }
            let version=try db.statement("PRAGMA user_version");defer {sqlite3_finalize(version)};XCTAssertEqual(sqlite3_step(version),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(version,0),20)
        }
        XCTAssertEqual(try store.activityCalendar(request(filter:SearchFilter(kind:.screen,favoritesOnly:true,tag:"release"))).totalSources,1)
    }
    func testCancellationDuringStatementPreparationReleasesConnectionForRetry() async throws {
        try add("owned","2024-03-01T00:00:00-05:00");let gate=ActivitySQLGate(),store=self.store!,request=try request()
        _ = try store.withRoutineDatabase {db in
            sqlite3_set_authorizer(db.handle,{pointer,action,table,_,_,_ in
                if action==SQLITE_READ,let table,String(cString:table)=="memories",let pointer {Unmanaged<ActivitySQLGate>.fromOpaque(pointer).takeUnretainedValue().wait()};return SQLITE_OK
            },Unmanaged.passUnretained(gate).toOpaque())
        }
        defer {_ = try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        let task=Task.detached {try store.activityCalendar(request)};await fulfillment(of:[gate.entered],timeout:5);task.cancel();gate.release()
        do {_=try await task.value;XCTFail("Cancelled calendar query published")}catch is CancellationError {}catch {XCTFail("Unexpected \(error)")}
        XCTAssertEqual(try store.activityCalendar(request).totalSources,1)
    }
}
