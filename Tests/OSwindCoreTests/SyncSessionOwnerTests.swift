import XCTest
@testable import OSwindCore

extension SyncOutgoingTests {
    func expectSessionPhase(_ session:PersonalSyncSession,_ phase:PersonalSyncStatus.Phase,file:StaticString=#filePath,line:UInt=#line)async {let status=await session.status();XCTAssertEqual(status.phase,phase,file:file,line:line)}
    func testSessionOwnerSuspendsAllProcessingAndResumesActualThirteenKindDelivery()async throws {
        try seedGraph()
        try await withServicePairAsync {f in
            let session=try PersonalSyncSession(service:f.a,schedule:.init(activeSeconds:0.005,idleSeconds:0.01,retrySeconds:0.01))
            XCTAssertTrue(session.belongs(to:store));XCTAssertFalse(session.belongs(to:f.receiver))
            try await session.setProcessingEnabled(false)
            await expectSessionPhase(session,.suspended)
            try store.insert(Memory(id:"owned-paused",kind:.note,title:"Held while suspended",text:"Owned pause source"))
            try await Task.sleep(for:.milliseconds(40))
            XCTAssertNil(try f.transport.serviceHead(replica:replica),"Processing suspension must not even publish a discovery head")
            XCTAssertGreaterThan(try serviceCount(store,"personal_sync_changes"),0)
            try await session.setNetworkEnabled(false)
            try await session.setProcessingEnabled(true)
            for _ in 0..<1000 {
                if await session.status().phase == .networkPaused {break}
                try await Task.sleep(for:.milliseconds(5))
            }
            await expectSessionPhase(session,.networkPaused)
            XCTAssertEqual(try serviceCount(store,"personal_sync_changes"),0)
            XCTAssertNil(try f.transport.serviceHead(replica:replica))
            try await session.setNetworkEnabled(true)
            for _ in 0..<1000 {
                if let head=try f.transport.serviceHead(replica:replica),head.through==22 {break}
                try await Task.sleep(for:.milliseconds(5))
            }
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,22)
            _=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),4)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_bindings"),1)
            try await session.stop()
            await expectSessionPhase(session,.stopped)
            do {try await session.setProcessingEnabled(true);XCTFail("A stopped session restarted") }catch {}
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
            let first=await session.updates(),second=await session.updates()
            let cancelled=Task {for await _ in first {if Task.isCancelled {break}}}
            let retained=Task {()->[PersonalSyncStatus.Phase] in
                var values=[PersonalSyncStatus.Phase]();for await value in second {values.append(value.phase)};return values
            }
            cancelled.cancel();await cancelled.value
            try store.insert(Memory(id:"observer-owned",kind:.note,text:"Owned source after observer cancellation"))
            try await session.setProcessingEnabled(true)
            for _ in 0..<1000 {
                if let head=try f.transport.serviceHead(replica:replica),head.through==1 {break}
                try await Task.sleep(for:.milliseconds(5))
            }
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,1)
            _=try serviceReady(f.b,limit:64);XCTAssertEqual(try serviceCount(f.receiver,"memories"),1)
            try await session.stop();let values=await retained.value
            XCTAssertEqual(values.last,.stopped)
            XCTAssertTrue(f.localA.isClosed,"Joined session stop must release its private native spool descriptor")
        }
    }

}
