import XCTest
@testable import OSwindCore

final class RoutineTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func date(_ string:String) -> Date {ISO8601DateFormatter().date(from:string)!}
    var start:Date {date("2026-10-23T12:00:00Z")}
    func definition() -> RoutineDefinition {var d=RoutineDefinition();d.schedule.timeZone="UTC";d.schedule.hour=17;return d}
    func settings() -> AppSettings {var s=AppSettings();s.routinesEnabled=true;return s}
    func evidence(_ text:String="Synthetic owner is Mira.") throws -> Memory {let m=Memory(timestamp:start.addingTimeInterval(3600),kind:.note,app:"Notes",title:"Synthetic source",text:text);try store.insert(m);return m}
    actor Gate {let entered=XCTestExpectation(description:"generator entered");var next:CheckedContinuation<Void,Never>?;func wait() async {await withCheckedContinuation {next=$0;entered.fulfill()}};func open(){next?.resume();next=nil}}
    actor Count {var value=0;func add(){value += 1}}
    func answer(_ memory:Memory) -> Answer {Answer(text:"Mira owns it [1].",sources:[SearchHit(memory:memory,score:1,match:"fixture")],provider:"fixture",duration:0)}
    func testCalendarDSTWeekdaysAndPinnedTimeZone() throws {
        var s=RoutineSchedule();s.timeZone="America/Los_Angeles";s.hour=2;s.minute=30
        XCTAssertEqual(try s.occurrence(relativeTo:date("2026-03-08T09:59:00Z"),next:true),date("2026-03-08T10:00:00Z"))
        s.hour=1;s.minute=30
        XCTAssertEqual(try s.occurrence(relativeTo:date("2026-11-01T08:31:00Z"),next:true),date("2026-11-02T09:30:00Z"))
        XCTAssertEqual(try s.occurrence(relativeTo:date("2026-11-01T09:31:00Z"),next:false),date("2026-11-01T08:30:00Z"))
        s.weekdays=[2];s.hour=9;s.minute=0
        XCTAssertEqual(try s.occurrence(relativeTo:date("2026-10-23T12:00:00Z"),next:true),date("2026-10-26T16:00:00Z"))
        s.weekdays=[];XCTAssertThrowsError(try s.validated());s.weekdays=[1,1];XCTAssertThrowsError(try s.validated())
    }
    func testIntervalBoundariesCoalesceAndLegacyScheduleDefaults() throws {
        let old=try JSONDecoder().decode(RoutineSchedule.self,from:Data(#"{"hour":17,"timeZone":"UTC"}"#.utf8));XCTAssertEqual(old.cadence,.calendar)
        var d=definition();d.schedule.cadence = .interval;d.schedule.intervalMinutes=15;d.window = .lastHour
        let at=date("2026-10-23T12:22:31Z")
        XCTAssertEqual(try d.schedule.occurrence(relativeTo:at,next:true),date("2026-10-23T12:30:00Z"))
        XCTAssertEqual(try d.schedule.occurrence(relativeTo:at,next:false),date("2026-10-23T12:15:00Z"))
        _ = try store.saveRoutine(d,now:start);let claim=try XCTUnwrap(store.claimRoutine(now:date("2026-10-25T12:22:31Z")))
        XCTAssertEqual(claim.run.scheduledAt,date("2026-10-25T12:15:00Z"));XCTAssertEqual(claim.run.filter.end!.timeIntervalSince(claim.run.filter.start!),3600)
        _ = try store.finishRoutine(claim.run.id,status:.failed,message:"fixture")
        XCTAssertNil(try store.claimRoutine(now:date("2026-10-25T12:29:59Z")))
        d.schedule.intervalMinutes=0;XCTAssertThrowsError(try d.validated())
    }
    func testWindowsRespectCalendarDaysAndFixedHourLookbacks() throws {
        var d=definition();d.schedule.timeZone="America/Los_Angeles";d.window = .yesterday
        let f=try d.filter(at:date("2026-03-09T16:00:00Z"));XCTAssertEqual(f.end!.timeIntervalSince(f.start!),23*3600)
        d.window = .last24Hours;let fixed=try d.filter(at:date("2026-03-09T16:00:00Z"));XCTAssertEqual(fixed.end!.timeIntervalSince(fixed.start!),86400)
        d.window = .yesterday;let fall=try d.filter(at:date("2026-11-02T16:00:00Z"));XCTAssertEqual(fall.end!.timeIntervalSince(fall.start!),25*3600)
    }
    func testSanitizedPersistenceConflictAndLegacyDefaults() throws {
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8)).routinesEnabled)
        var d=definition();d.prompt="password=supersecret123 Please summarize.";let first=try store.saveRoutine(d,now:start)
        XCTAssertFalse(first.definition.prompt.contains("supersecret123"));XCTAssertEqual(first.nextDue,date("2026-10-23T17:00:00Z"))
        XCTAssertThrowsError(try store.saveRoutine(d,now:start));let updated=try store.saveRoutine(d,expectedRevision:1,now:start);XCTAssertEqual(updated.revision,2)
        XCTAssertThrowsError(try store.saveRoutine(d,expectedRevision:1,now:start))
        d.ai.provider = .compatible;d.ai.endpoint="https://user:secret@example.com";XCTAssertThrowsError(try store.saveRoutine(d,now:start))
    }
    func testEncodedPayloadAndRevisionLimitsFailBeforeMutation() throws {
        var d=definition();d.prompt=String(repeating:"\u{1}",count:8000)
        XCTAssertThrowsError(try store.saveRoutine(d,now:start));XCTAssertTrue(try store.routines().isEmpty)
        let saved=try store.saveRoutine(definition(),now:start)
        try store.withRoutineDatabase {try $0.execute("UPDATE routines SET revision=9223372036854775807")}
        XCTAssertThrowsError(try store.saveRoutine(saved.definition,expectedRevision:Int.max,now:start))
        XCTAssertEqual(try store.routines().first?.revision,Int.max)
    }
    func testConcurrentConnectionsClaimOneSlotAndConsumeFailures() async throws {
        let saved=try store.saveRoutine(definition(),now:start),second=try MemoryStore(root:store.root),at=date("2026-10-23T17:01:00Z")
        let claims=try await withThrowingTaskGroup(of:RoutineClaim?.self) {group in
            for i in 0..<12 {let target=i%2==0 ? store! : second;group.addTask {try target.claimRoutine(now:at)}}
            var claims=[RoutineClaim]();for try await result in group {if let result {claims.append(result)}};return claims
        }
        XCTAssertEqual(claims.count,1);let claim=try XCTUnwrap(claims.first)
        _ = try store.finishRoutine(claim.run.id,status:.failed,message:"fixture failed")
        XCTAssertNil(try second.claimRoutine(now:at));XCTAssertEqual(try second.routines().first?.nextDue,date("2026-10-24T17:00:00Z"))
        XCTAssertNil(try store.claimRoutine(now:date("2026-10-23T16:59:00Z")));XCTAssertEqual(try store.routineRuns(saved.id).count,1)
    }
    func testStaleRunRecoveryNeverRetriesClaimedSlot() throws {
        _ = try store.saveRoutine(definition(),now:start);let first=try XCTUnwrap(store.claimRoutine(now:date("2026-10-23T17:00:00Z")))
        XCTAssertNil(try store.claimRoutine(now:date("2026-10-23T17:16:00Z")))
        XCTAssertEqual(try store.routineRuns().first?.status,.interrupted)
        let manual=try XCTUnwrap(store.claimRoutine(id:first.run.routineID,now:date("2026-10-23T17:17:00Z")))
        XCTAssertEqual(manual.run.trigger,.manual);XCTAssertNotEqual(first.run.id,manual.run.id)
    }
    func testBoundedWakeCatchUpAndOldWeeklyOccurrenceSkip() throws {
        var d=definition();d.schedule.weekdays=[2];_ = try store.saveRoutine(d,now:start)
        let wake=date("2026-11-05T12:00:00Z"),claim=try XCTUnwrap(store.claimRoutine(now:wake))
        XCTAssertEqual(claim.run.status,.skipped);XCTAssertEqual(claim.run.scheduledAt,date("2026-11-02T17:00:00Z"));XCTAssertNil(try store.claimRoutine(now:wake))
    }
    func testRealEvidenceRunnerPersistsCitationsAndErasureInvalidatesOutput() async throws {
        let memory=try evidence(),d=try store.saveRoutine(definition(),now:start)
        let runner=RoutineRunner(store:store,embedder:LocalEmbedder())
        let first=try await runner.runDue(settings:settings(),now:date("2026-10-23T17:00:00Z"));let run=try XCTUnwrap(first)
        XCTAssertEqual(run.status,.completed);XCTAssertTrue(run.resultAvailable)
        let turns=try store.chatTurns(try XCTUnwrap(run.chatID));XCTAssertEqual(turns.count,1);XCTAssertEqual(turns[0].answer.sources.map(\.id),[memory.id]);XCTAssertEqual(turns[0].filter.end,run.scheduledAt)
        let again=try await runner.runDue(settings:settings(),now:date("2026-10-23T17:01:00Z"));XCTAssertNil(again)
        try store.delete(memory.id);XCTAssertEqual(try store.chatTurns(run.chatID!).count,0);XCTAssertFalse(try store.routineRuns(d.id)[0].resultAvailable)
        try store.deleteRoutine(d.id);XCTAssertTrue(try store.routineRuns().isEmpty);XCTAssertNil(try store.chat(run.chatID!))
    }
    func testMissingEvidenceRollsBackChatAndMarksFailure() async throws {
        let memory=try evidence();_ = try store.saveRoutine(definition(),now:start)
        let store=self.store!,result=answer(memory)
        let runner=RoutineRunner(store:store,generate:{_,_,_,_ in try store.delete(memory.id);return result})
        let value=try await runner.runDue(settings:settings(),now:date("2026-10-23T17:00:00Z"));XCTAssertEqual(value?.status,.failed);XCTAssertTrue(try store.chats().isEmpty)
    }
    func testChangedDefinitionAndCancellationDiscardLateResults() async throws {
        let memory=try evidence(),saved=try store.saveRoutine(definition(),now:start),gate=Gate(),result=answer(memory)
        let runner=RoutineRunner(store:store,generate:{_,_,_,_ in await gate.wait();return result})
        let task=Task {try await runner.runNow(saved.id,settings:settings(),now:start.addingTimeInterval(7200))}
        await fulfillment(of:[gate.entered],timeout:5)
        var changed=saved.definition;changed.enabled=false;_ = try store.saveRoutine(changed,expectedRevision:saved.revision,now:start)
        await gate.open();let value=try await task.value;XCTAssertEqual(value?.status,.cancelled);XCTAssertTrue(try store.chats().isEmpty)
        let gate2=Gate(),cancelledRunner=RoutineRunner(store:store,generate:{_,_,_,_ in await gate2.wait();return result})
        let cancelled=Task {try await cancelledRunner.runNow(saved.id,settings:settings(),now:start.addingTimeInterval(7201))}
        await fulfillment(of:[gate2.entered],timeout:5);cancelled.cancel();await gate2.open()
        do {_ = try await cancelled.value;XCTFail("Cancelled run published")} catch is CancellationError {} catch {throw error}
        XCTAssertEqual(try store.routineRuns().first?.status,.cancelled);XCTAssertTrue(try store.chats().isEmpty)
    }
    func testURLSessionTransportCancellationIsNotACompletedOrFailedResult() async throws {
        let saved=try store.saveRoutine(definition(),now:start),gate=Gate()
        let runner=RoutineRunner(store:store,generate:{_,_,_,_ in await gate.wait();throw URLError(.cancelled)})
        let task=Task {try await runner.runNow(saved.id,settings:settings(),now:start)}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();await gate.open()
        do {_ = try await task.value;XCTFail("Transport cancellation succeeded")} catch is CancellationError {} catch {throw error}
        XCTAssertEqual(try store.routineRuns().first?.status,.cancelled);XCTAssertTrue(try store.chats().isEmpty)
    }
    func testRemoteOptInsAndDisabledSchedulerPreventGeneration() async throws {
        var d=definition();d.ai.provider = .compatible;d.ai.endpoint="https://example.invalid";d.ai.allowRemote=true
        let saved=try store.saveRoutine(d,now:start),count=Count(),runner=RoutineRunner(store:store,generate:{_,_,_,_ in await count.add();return Answer(text:"unused",sources:[],provider:"fixture",duration:0)})
        let skipped=try await runner.runDue(settings:AppSettings(),now:date("2026-10-23T17:00:00Z"));XCTAssertNil(skipped)
        let denied=try await runner.runNow(saved.id,settings:settings(),now:start);XCTAssertEqual(denied?.status,.failed)
        var allow=settings();allow.ai.allowRemote=true
        let stillDenied=try await runner.runNow(saved.id,settings:allow,now:start.addingTimeInterval(1));XCTAssertEqual(stillDenied?.status,.failed)
        var updated=d;updated.allowRemote=true;_ = try store.saveRoutine(updated,expectedRevision:1,now:start)
        let accepted=try await runner.runNow(saved.id,settings:allow,now:start.addingTimeInterval(2));XCTAssertEqual(accepted?.status,.completed);let calls=await count.value;XCTAssertEqual(calls,1)
    }
    func testCompleteBackupRestoresDefinitionsHistoryAndQuietScheduling() async throws {
        _ = try evidence();let saved=try store.saveRoutine(definition(),now:start),runner=RoutineRunner(store:store,embedder:LocalEmbedder())
        let finished=try await runner.runNow(saved.id,settings:settings(),now:start.addingTimeInterval(7200));XCTAssertEqual(finished?.status,.completed)
        _ = try store.claimRoutine(id:saved.id,now:start.addingTimeInterval(7300));try settings().save(root:store.root)
        let archive=root.appendingPathComponent("routines.oswindbackup"),restored=root.appendingPathComponent("restored")
        _ = try LibraryBackup.create(store:store,destination:archive);_ = try LibraryBackup.restore(archive,to:restored)
        let reopened=try MemoryStore(root:restored);XCTAssertEqual(try reopened.routines().map(\.definition),[saved.definition]);XCTAssertFalse(AppSettings.load(root:restored).routinesEnabled)
        let runs=try reopened.routineRuns();XCTAssertEqual(Set(runs.map(\.status)),Set([.completed,.interrupted]));XCTAssertTrue(runs.contains(where:{$0.resultAvailable}))
        try reopened.deleteAll();XCTAssertTrue(try reopened.routines().isEmpty);XCTAssertTrue(try reopened.routineRuns().isEmpty)
    }
}
