import XCTest
@testable import OSwindCore

extension SyncOutgoingTests {
    func expectSessionPhase(_ session:PersonalSyncSession,_ phase:PersonalSyncStatus.Phase,file:StaticString=#filePath,line:UInt=#line)async {let status=await session.status();XCTAssertEqual(status.phase,phase,file:file,line:line)}
    /// Wait for the actual acknowledged transition. A fixed count of 5ms polls
    /// assumed preparation finished in roughly five seconds and continued into
    /// delivery assertions when sanitizer-instrumented all-kind work did not.
    /// The deadline bounds a genuinely stuck worker; no later assertion runs
    /// after a failed transition. Cancellation also removes the subscription.
    func awaitSessionPhase(_ session:PersonalSyncSession,_ phase:PersonalSyncStatus.Phase)async throws {
        let stream=await session.updates(),started=ContinuousClock.now
        try await withThrowingTaskGroup(of:Void.self) {tasks in
            tasks.addTask {
                for await state in stream {
                    try Task.checkCancellation()
                    if state.phase==phase {return}
                    if state.phase == .failed || state.phase == .stopped {throw OSwindError.unavailable("Owned session ended before its expected phase")}
                }
                throw OSwindError.unavailable("Owned session observation ended before its expected phase")
            }
            tasks.addTask {try await Task.sleep(for:.seconds(60));throw OSwindError.unavailable("Owned session did not acknowledge its expected phase before deadline")}
            defer {tasks.cancelAll()}
            _=try await tasks.next()
        }
        print("SYNC_SESSION_PHASE phase=\(phase) elapsed=\(started.duration(to:.now))")
    }
    func testSessionOwnerSuspendsAllProcessingAndResumesActualThirteenKindDelivery()async throws {
        try seedGraph()
        try await withServicePairAsync {f in
            let session=try PersonalSyncSession(service:f.a,schedule:.init(activeSeconds:0.005,idleSeconds:0.01,retrySeconds:0.01))
            do {
            XCTAssertTrue(session.belongs(to:store));XCTAssertFalse(session.belongs(to:f.receiver))
            try await session.setProcessingEnabled(false)
            await expectSessionPhase(session,.suspended)
            try store.insert(Memory(id:"owned-paused",kind:.note,title:"Held while suspended",text:"Owned pause source"))
            try await Task.sleep(for:.milliseconds(40))
            XCTAssertNil(try f.transport.serviceHead(replica:replica),"Processing suspension must not even publish a discovery head")
            XCTAssertGreaterThan(try serviceCount(store,"personal_sync_changes"),0)
            try await session.setNetworkEnabled(false)
            try await session.setProcessingEnabled(true)
            try await awaitSessionPhase(session,.networkPaused)
            await expectSessionPhase(session,.networkPaused)
            XCTAssertEqual(try serviceCount(store,"personal_sync_changes"),0)
            XCTAssertNil(try f.transport.serviceHead(replica:replica))
            try await session.setNetworkEnabled(true)
            try await awaitSessionPhase(session,.upToDate)
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,22)
            _=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),4)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_bindings"),1)
            try await session.stop()
            await expectSessionPhase(session,.stopped)
            do {try await session.setProcessingEnabled(true);XCTFail("A stopped session restarted") }catch {}
            }catch {try? await session.stop();throw error}
        }
    }
    func testSessionOwnerPushStreamFinishesAfterJoinedStopWithoutAnotherWorker()async throws {
        try await withServicePairAsync {f in
            let session=try PersonalSyncSession(service:f.a)
            let stream=await session.updates()
            let received=Task {()->[PersonalSyncStatus.Phase] in
                var phases=[PersonalSyncStatus.Phase]()
                for await status in stream {phases.append(status.phase)}
                return phases
            }
            try await session.setProcessingEnabled(false)
            try await session.stop()
            let phases=await received.value
            XCTAssertEqual(phases.last,.stopped)
            let terminal=await session.updates();var last:PersonalSyncStatus?
            for await value in terminal {last=value}
            XCTAssertEqual(last?.phase,.stopped)
        }
    }
    func testSessionOwnerConcurrentSuspendNetworkChangeAndStopNeverRestartsWorker()async throws {
        try await withServicePairAsync {f in
            let session=try PersonalSyncSession(service:f.a,schedule:.init(activeSeconds:0.005,idleSeconds:0.01,retrySeconds:0.01))
            try await session.setProcessingEnabled(true)
            await withTaskGroup(of:Void.self) {tasks in
                tasks.addTask {try? await session.setNetworkEnabled(false)}
                tasks.addTask {try? await session.setProcessingEnabled(false)}
                tasks.addTask {try? await session.setProcessingEnabled(false)}
                tasks.addTask {try? await session.stop()}
                tasks.addTask {try? await session.stop()}
            }
            await expectSessionPhase(session,.stopped)
            let head=try f.transport.serviceHead(replica:replica)
            try await Task.sleep(for:.milliseconds(40))
            XCTAssertEqual(try f.transport.serviceHead(replica:replica),head)
            do {try await session.setNetworkEnabled(true);XCTFail("Stopped session changed network") }catch {}
        }
    }
    func testSessionOwnerCancellingOneStatusConsumerDoesNotStopDeliveryOrOtherConsumers()async throws {
        try await withServicePairAsync {f in
            let session=try PersonalSyncSession(service:f.a,schedule:.init(activeSeconds:0.005,idleSeconds:0.01,retrySeconds:0.01))
            do {
            let first=await session.updates(),second=await session.updates()
            let cancelled=Task {for await _ in first {if Task.isCancelled {break}}}
            let retained=Task {()->[PersonalSyncStatus.Phase] in
                var values=[PersonalSyncStatus.Phase]();for await value in second {values.append(value.phase)};return values
            }
            cancelled.cancel();await cancelled.value
            try store.insert(Memory(id:"observer-owned",kind:.note,text:"Owned source after observer cancellation"))
            try await session.setProcessingEnabled(true)
            try await awaitSessionPhase(session,.upToDate)
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,1)
            _=try serviceReady(f.b,limit:64);XCTAssertEqual(try serviceCount(f.receiver,"memories"),1)
            try await session.stop();let values=await retained.value
            XCTAssertEqual(values.last,.stopped)
            XCTAssertTrue(f.localA.isClosed,"Joined session stop must release its private native spool descriptor")
            }catch {try? await session.stop();throw error}
        }
    }

}
