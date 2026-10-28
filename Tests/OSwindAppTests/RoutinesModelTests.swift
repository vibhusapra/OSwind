import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class RoutinesModelTests:XCTestCase {
    actor Count {var due=0,manual=0;func tick(){due += 1};func run(){manual += 1}}
    actor Gate {let entered=XCTestExpectation(description:"scheduled run entered");var next:CheckedContinuation<Void,Never>?;func wait() async {await withCheckedContinuation {next=$0;entered.fulfill()}};func open(){next?.resume();next=nil}}
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func eventually(_ predicate:@escaping () async -> Bool) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !(await predicate()) && ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(1))}
        let value=await predicate();XCTAssertTrue(value)
    }
    func testActualTimerPausedGateEnableAndStop() async throws {
        let count=Count(),model=RoutinesModel(store:store,settings:AppSettings(),interval:0.03,due:{_,_ in await count.tick();return nil},manual:{_,_,_ in await count.run();return nil})
        model.start();try await Task.sleep(for:.milliseconds(70));let before=await count.due;XCTAssertEqual(before,0)
        var enabled=AppSettings();enabled.routinesEnabled=true;model.apply(enabled)
        try await eventually {await count.due>=2};model.stop();try await eventually {!model.busy}
        let stopped=await count.due;try await Task.sleep(for:.milliseconds(70));let after=await count.due;XCTAssertEqual(stopped,after)
    }
    func testManualRunWorksWhileSchedulesOffAndDoesNotOverlap() async throws {
        let gate=Gate(),count=Count(),model=RoutinesModel(store:store,settings:AppSettings(),due:{_,_ in await count.tick();return nil},manual:{_,_,_ in await count.run();await gate.wait();try Task.checkCancellation();return nil})
        model.runNow("fixture");await fulfillment(of:[gate.entered],timeout:5);model.runNow("other");model.tick()
        let manual=await count.manual,due=await count.due;XCTAssertEqual(manual,1);XCTAssertEqual(due,0);XCTAssertTrue(model.busy)
        model.cancel();await gate.open();try await eventually {!model.busy};XCTAssertNil(model.activeRoutineID)
    }
    func testDisablingSchedulesCancelsCurrentWork() async throws {
        let gate=Gate();var config=AppSettings();config.routinesEnabled=true
        let model=RoutinesModel(store:store,settings:config,due:{_,_ in await gate.wait();try Task.checkCancellation();return nil},manual:{_,_,_ in nil})
        model.tick();await fulfillment(of:[gate.entered],timeout:5);model.apply(AppSettings());await gate.open();try await eventually {!model.busy};XCTAssertNil(model.error)
    }
    func testStoppedSchedulerRejectsLateAutomaticTickButManualRunStillWorks()async throws {
        let count=Count();var settings=AppSettings();settings.routinesEnabled=true
        let model=RoutinesModel(store:store,settings:settings,due:{_,_ in await count.tick();return nil},manual:{_,_,_ in await count.run();return nil})
        model.start();try await eventually {await count.due==1};try await eventually {!model.busy};model.stop()
        model.tickIfStarted();try await Task.sleep(for:.milliseconds(20));let due=await count.due;XCTAssertEqual(due,1)
        model.runNow("owned-manual");try await eventually {await count.manual==1};try await eventually {!model.busy}
    }
    func testAutomaticRunDefinitionChangeCancelsAndNoResultPublishes() async throws {
        let saved=try store.saveRoutine(RoutineDefinition()),gate=Gate(),source=Memory(text:"Synthetic source")
        try store.insert(source);var settings=AppSettings();settings.routinesEnabled=true
        let runner=RoutineRunner(store:store,generate:{_,_,_,_ in await gate.wait();return Answer(text:"Result [1]",sources:[SearchHit(memory:source,score:1,match:"fixture")],provider:"fixture",duration:0)})
        // Use manual claim inside the injected automatic entry to avoid relying
        // on the wall-clock schedule; model active ID is deliberately nil.
        let model=RoutinesModel(store:store,settings:settings,due:{s,n in try await runner.runNow(saved.id,settings:s,now:n)},manual:{_,_,_ in nil})
        model.tick();await fulfillment(of:[gate.entered],timeout:5)
        var updated=saved.definition;updated.enabled=false;XCTAssertTrue(model.save(updated,revision:saved.revision));await gate.open();try await eventually {!model.busy}
        XCTAssertTrue(try store.chats().isEmpty);XCTAssertEqual(try store.routineRuns().first?.status,.cancelled)
    }
}
