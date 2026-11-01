import XCTest
import CSQLite
@testable import OSwindCore

final class MeetingContextTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_793_490_000)
    let identity=String(repeating:"a",count:32)
    func configuration(_ library:String?=nil)->MeetingContextConfiguration {
        var c=MeetingContextConfiguration();c.enabled=true;c.calendarIDs=["owned-calendar"];c.boundLibrary=library ?? identity;c.reminders=true;return c
    }
    func event(calendar:String="owned-calendar",series:String="owned-event",start:Date?=nil,original:Date?=nil,title:String="Orion review",url:URL?=nil,allDay:Bool=false,cancelled:Bool=false,declined:Bool=false)throws->MeetingOccurrence {
        let date=start ?? now.addingTimeInterval(60)
        return try .init(calendarID:calendar,seriesID:series,originalOccurrence:original,start:date,end:date.addingTimeInterval(1800),title:title,participants:["Mira"],joinURL:url,allDay:allDay,cancelled:cancelled,declined:declined,timeZone:"America/Los_Angeles")
    }
    func testDefaultsAndLegacySettingsNeverEnableCalendarReads()throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8));XCTAssertFalse(old.meetings.enabled);XCTAssertTrue(old.meetings.calendarIDs.isEmpty)
        XCTAssertTrue(try MeetingContextPlanner.make(events:[event()],configuration:old.meetings,libraryIdentity:identity,policy:.init(),now:now).upcoming.isEmpty)
    }
    func testMalformedCalendarSettingsPreserveOtherPrivacyAndStayDisabled()throws {
        var saved=AppSettings();saved.privacy.excludedApps=["owned.private"]
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(saved)) as? [String:Any]);json["meetings"]=["enabled":true,"calendarIDs":["unexpected"]]
        let result=try JSONDecoder().decode(AppSettings.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertFalse(result.meetings.enabled);XCTAssertEqual(result.privacy.excludedApps,["owned.private"])
    }
    func testInvalidSelectionAndReminderIntervalsRefuse()throws {
        var c=configuration();c.calendarIDs=[];XCTAssertThrowsError(try c.validate())
        c=configuration();c.calendarIDs=["same","same"];XCTAssertThrowsError(try c.validate())
        c=configuration();c.calendarIDs=["bad\0id"];XCTAssertThrowsError(try c.validate())
        c=configuration();c.leadMinutes=3;XCTAssertThrowsError(try c.validate())
        c=configuration();c.boundLibrary=nil;XCTAssertThrowsError(try c.validate())
    }
    func testSelectionComparesCompleteIdentifierBytes()throws {
        var a=configuration(),b=configuration();a.calendarIDs=["caf\u{e9}"];b.calendarIDs=["cafe\u{301}"]
        XCTAssertNotEqual(a,b);XCTAssertFalse(a.containsCalendar(b.calendarIDs[0]));try a.validate();try b.validate()
    }
    func testWrongLibraryNeverProducesMeetingsOrReminders()throws {
        let plan=try MeetingContextPlanner.make(events:[event()],configuration:configuration(),libraryIdentity:String(repeating:"b",count:32),policy:.init(),now:now)
        XCTAssertTrue(plan.upcoming.isEmpty);XCTAssertTrue(plan.due.isEmpty)
    }
    func testSelectedScopeAndDueWindowExcludeOtherCalendarsCancelledDeclinedAndAllDayReminders()throws {
        let e=try event(),day=try event(series:"all-day",allDay:true)
        let plan=try MeetingContextPlanner.make(events:[event(calendar:"other"),event(series:"cancelled",cancelled:true),event(series:"declined",declined:true),e,day],configuration:configuration(),libraryIdentity:identity,policy:.init(),now:now)
        XCTAssertEqual(Set(plan.upcoming.map(\.id)),[e.id,day.id]);XCTAssertEqual(plan.due.map(\.id),[e.id])
        let late=try MeetingContextPlanner.make(events:[e],configuration:configuration(),libraryIdentity:identity,policy:.init(),now:e.start.addingTimeInterval(121));XCTAssertTrue(late.due.isEmpty)
    }
    func testPrivacyBlocksCalendarApplicationTitlesAndJoinDomains()throws {
        let e=try event(url:XCTUnwrap(URL(string:"https://blocked.example/join")))
        var policy=PrivacyPolicy();policy.excludedApps.append("com.apple.iCal")
        XCTAssertTrue(try MeetingContextPlanner.make(events:[e],configuration:configuration(),libraryIdentity:identity,policy:policy,now:now).upcoming.isEmpty)
        policy=PrivacyPolicy();policy.excludedDomains=["blocked.example"]
        XCTAssertTrue(try MeetingContextPlanner.make(events:[e],configuration:configuration(),libraryIdentity:identity,policy:policy,now:now).upcoming.isEmpty)
        policy=PrivacyPolicy();policy.excludedTitles=["Orion"]
        XCTAssertThrowsError(try e.briefQuestion(policy:policy,includeParticipants:true))
    }
    func testMovedRecurrenceKeepsOccurrenceIdentityButGetsNewReminderTime()throws {
        let first=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-11-01T01:30:00-07:00")),second=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-11-01T01:30:00-08:00"))
        let original=try event(start:first,original:first),moved=try event(start:first.addingTimeInterval(7200),original:first),next=try event(start:second,original:second)
        XCTAssertEqual(original.id,moved.id);XCTAssertNotEqual(original.reminderKey(leadMinutes:5),moved.reminderKey(leadMinutes:5));XCTAssertNotEqual(original.id,next.id)
    }
    func testConflictingSnapshotsRefuseInsteadOfSelectingAnOldOccurrence()throws {
        let a=try event(),b=try event(title:"Changed meeting")
        XCTAssertThrowsError(try MeetingContextPlanner.make(events:[a,b],configuration:configuration(),libraryIdentity:identity,policy:.init(),now:now))
        let exact=try MeetingContextPlanner.make(events:[a,a],configuration:configuration(),libraryIdentity:identity,policy:.init(),now:now);XCTAssertEqual(exact.upcoming.count,1)
    }
    func testModelQuestionOmitsJoinTokensAndParticipantsUnlessEnabled()throws {
        let e=try event(title:"Orion api_key=owned-secret-value",url:XCTUnwrap(URL(string:"https://meeting.example/join?token=NeverSendThis")))
        let plain=try e.briefQuestion(policy:.init(),includeParticipants:false),people=try e.briefQuestion(policy:.init(),includeParticipants:true)
        XCTAssertFalse(plain.contains("NeverSendThis"));XCTAssertFalse(plain.contains("meeting.example"));XCTAssertFalse(plain.contains("owned-secret-value"));XCTAssertFalse(plain.contains("Mira"));XCTAssertTrue(people.contains("Mira"));XCTAssertTrue(plain.contains("[REDACTED]"))
    }
    func testJoinLinksOnlyAcceptBoundedHTTPSWithoutEmbeddedCredentials()throws {
        for value in ["javascript:alert(1)","file:///tmp/owned","http://meeting.example/","https://user:password@meeting.example/","https://meeting.example/\nnext",String(repeating:"x",count:5000)] {XCTAssertNil(MeetingJoinLink.validate(value),value)}
        XCTAssertEqual(MeetingJoinLink.first(in:["Conference room","Join https://meeting.example/owned"])?.host,"meeting.example")
    }
    func testQuietRestoreClearsExecutionSelectionAndLibraryBinding()throws {
        var settings=AppSettings();settings.meetings=configuration();let quiet=LibraryBackup.quietSettings(settings)
        XCTAssertFalse(quiet.meetings.enabled);XCTAssertFalse(quiet.meetings.reminders);XCTAssertTrue(quiet.meetings.calendarIDs.isEmpty);XCTAssertNil(quiet.meetings.boundLibrary)
    }
    func testReminderReceiptsSurviveReopenAndDoNotRewriteDuplicates()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-ledger-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let first=try MemoryStore(root:root),id=try first.authorizeMeetingLibrary(),c=configuration(id),e=try event()
        XCTAssertEqual(try first.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now),[e.reminderKey(leadMinutes:5)])
        let changes=try first.withRoutineDatabase {sqlite3_total_changes64($0.handle)}
        XCTAssertTrue(try first.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now).isEmpty)
        XCTAssertEqual(try first.withRoutineDatabase {sqlite3_total_changes64($0.handle)},changes)
        try first.close();let reopened=try MemoryStore(root:root);defer {try? reopened.close()}
        XCTAssertTrue(try reopened.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now).isEmpty)
        let raw=try reopened.withRoutineDatabase {db in let row=try db.statement("SELECT value FROM store_metadata WHERE key='meeting-reminder-receipts-v1'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return db.text(row,0)}
        XCTAssertFalse(raw.contains(e.title));XCTAssertFalse(raw.contains(e.seriesID));XCTAssertFalse(raw.contains("Mira"))
    }
    func testMalformedLedgerDoesNotResetAndDuplicateAClaim()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-ledger-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let id=try store.authorizeMeetingLibrary(),c=configuration(id)
        try store.withRoutineDatabase {try $0.execute("INSERT INTO store_metadata VALUES('meeting-reminder-receipts-v1','invalid-json')")}
        XCTAssertThrowsError(try store.claimMeetingReminders([event()],configuration:c,expectedLibrary:id,now:now))
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM store_metadata WHERE key='meeting-reminder-receipts-v1' AND value='invalid-json'")},1)
    }
    func testScalarAndByteBoundsDoNotExpandForOneHugeGraphemeOrCutAJoinURL()throws {
        let huge="A"+String(repeating:"\u{301}",count:50_000)
        let e=try event(title:huge);XCTAssertLessThanOrEqual(e.title.unicodeScalars.count,300);XCTAssertLessThanOrEqual(e.title.utf8.count,1200)
        let notes=String(repeating:" ",count:16_360)+"https://meeting.example/"+String(repeating:"x",count:100)
        XCTAssertNil(MeetingJoinLink.first(in:[notes]))
    }

    func testJoinURLsAndEmailAddressesEmbeddedInLabelsAreOmittedFromBrief()throws {
        let e=try MeetingOccurrence(calendarID:"owned-calendar",seriesID:"owned",start:now,end:now.addingTimeInterval(60),title:"Review https://meeting.example/join?opaque=NeverSendTitle",participants:["person@example.test","Mira https://meeting.example/?opaque=NeverSendName"])
        let question=try e.briefQuestion(policy:.init(),includeParticipants:true)
        XCTAssertFalse(question.contains("NeverSendTitle"));XCTAssertFalse(question.contains("NeverSendName"));XCTAssertFalse(question.contains("person@example.test"));XCTAssertTrue(question.contains("Mira"))
    }
    func testClaimBatchRefusalRollsBackAndRestoresConnectionDurability()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-rollback-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let id=try store.authorizeMeetingLibrary(),c=configuration(id),e=try event()
        let prior=try store.withRoutineDatabase {db in try db.execute("PRAGMA synchronous=NORMAL");return try db.eraseCount("PRAGMA synchronous")}
        try store.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_meeting_fail BEFORE INSERT ON store_metadata WHEN new.key='meeting-reminder-receipts-v1' BEGIN SELECT RAISE(ABORT,'owned injected ledger failure'); END")}
        XCTAssertThrowsError(try store.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now))
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM store_metadata WHERE key='meeting-reminder-receipts-v1'")},0)
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("PRAGMA synchronous")},prior)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_meeting_fail")}
        XCTAssertEqual(try store.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now).count,1)
    }
    func testTwoConnectionsCompeteForOneDurableReminderClaim()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-race-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let first=try MemoryStore(root:root),second=try MemoryStore(root:root);defer {try? first.close();try? second.close()}
        let id=try first.authorizeMeetingLibrary(),c=configuration(id),e=try event(),date=now
        async let a=Task.detached {try first.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:date)}.value
        async let b=Task.detached {try second.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:date)}.value
        let results=try await [a,b];XCTAssertEqual(results.flatMap {$0},[e.reminderKey(leadMinutes:5)])
    }
    func testWipeRemovesReminderMetadataAndRejectsOldLibraryAuthorization()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-wipe-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let id=try store.authorizeMeetingLibrary(),c=configuration(id),e=try event()
        _=try store.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now);_=try store.wipeLibrary()
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM store_metadata WHERE key='meeting-reminder-receipts-v1'")},0)
        XCTAssertThrowsError(try store.claimMeetingReminders([e],configuration:c,expectedLibrary:id,now:now))
        let new=try store.authorizeMeetingLibrary();XCTAssertNotEqual(new,id)
        XCTAssertEqual(try store.claimMeetingReminders([e],configuration:configuration(new),expectedLibrary:new,now:now).count,1)
    }

    func testCalendarAuthorizationIsReadOnlyUntilSelectionAndSurvivesCacheEpochRotation()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-identity-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        XCTAssertNil(try store.meetingLibraryIdentity())
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM store_metadata WHERE key='meeting-library-lifetime-v1'")},0)
        let id=try store.authorizeMeetingLibrary(),changes=try store.withRoutineDatabase {sqlite3_total_changes64($0.handle)}
        XCTAssertEqual(try store.authorizeMeetingLibrary(),id);XCTAssertEqual(try store.withRoutineDatabase {sqlite3_total_changes64($0.handle)},changes)
        let source=Memory(id:"owned-recap-parent",text:"Orion review decision");try store.insert(source)
        let recap=try store.saveRecap(.init(text:"Decision [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"evidence",duration:0))
        try store.delete(recap.id)
        XCTAssertEqual(try store.meetingLibraryIdentity(),id)
        XCTAssertEqual(try store.claimMeetingReminders([event()],configuration:configuration(id),expectedLibrary:id,now:now).count,1)
    }

    func testFullReceiptWindowRefusesNewClaimsWithoutEvictingUnexpiredOnes()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-capacity-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let id=try store.authorizeMeetingLibrary(),c=configuration(id)
        let events=try (0..<513).map {try event(series:"owned-\($0)")}
        for offset in stride(from:0,to:512,by:32) {XCTAssertEqual(try store.claimMeetingReminders(Array(events[offset..<offset+32]),configuration:c,expectedLibrary:id,now:now).count,32)}
        let changes=try store.withRoutineDatabase {sqlite3_total_changes64($0.handle)}
        XCTAssertThrowsError(try store.claimMeetingReminders([events[512]],configuration:c,expectedLibrary:id,now:now))
        XCTAssertEqual(try store.withRoutineDatabase {sqlite3_total_changes64($0.handle)},changes)
        XCTAssertTrue(try store.claimMeetingReminders([events[0]],configuration:c,expectedLibrary:id,now:now).isEmpty)
    }
    func testBriefMetadataFitsModelQuestionBoundWithWorstCaseQuotedNames()throws {
        let e=try MeetingOccurrence(calendarID:"owned-calendar",seriesID:"owned",start:now,end:now.addingTimeInterval(60),title:String(repeating:"\"",count:300),participants:Array(repeating:String(repeating:"\"",count:160),count:20))
        let question=try e.briefQuestion(policy:.init(),includeParticipants:true);XCTAssertLessThan(question.count,4000)
    }

    func testLibraryTokenRejectsNULTailAndBlobInsteadOfAcceptingTextPrefix()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-token-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let id=try store.authorizeMeetingLibrary(),c=configuration(id)
        try store.withRoutineDatabase {try $0.execute("UPDATE store_metadata SET value=value||char(0)||'tail' WHERE key='meeting-library-lifetime-v1'")}
        XCTAssertThrowsError(try store.meetingLibraryIdentity());XCTAssertThrowsError(try store.authorizeMeetingLibrary());XCTAssertThrowsError(try store.claimMeetingReminders([event()],configuration:c,expectedLibrary:id,now:now))
        try store.withRoutineDatabase {db in let row=try db.statement("UPDATE store_metadata SET value=CAST(? AS BLOB) WHERE key='meeting-library-lifetime-v1'");defer {sqlite3_finalize(row)};db.bind(row,1,id);try db.done(row)}
        XCTAssertThrowsError(try store.meetingLibraryIdentity())
    }
    func testLedgerRejectsNULTrailingBytesRatherThanDecodingOnlyTheJSONPrefix()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-ledger-tail-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let id=try store.authorizeMeetingLibrary(),c=configuration(id)
        _=try store.claimMeetingReminders([event()],configuration:c,expectedLibrary:id,now:now)
        try store.withRoutineDatabase {try $0.execute("UPDATE store_metadata SET value=value||char(0)||'tail' WHERE key='meeting-reminder-receipts-v1'")}
        XCTAssertThrowsError(try store.claimMeetingReminders([event(series:"second")],configuration:c,expectedLibrary:id,now:now))
    }

}
