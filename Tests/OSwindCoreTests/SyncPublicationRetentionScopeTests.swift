import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func folderMembers(_ folder:SyncObjectFolder)throws->[String] {
        try (FileManager.default.subpathsOfDirectory(atPath:folder.root.path)).sorted()
    }
    func testPublicationQueueForeignGroupInboxRefusesBeforeAnyContentOrNativeWrite()throws {try foreignInbox(epochOnly:false)}
    func testPublicationQueueForeignEpochInboxRefusesBeforeAnyContentOrNativeWrite()throws {try foreignInbox(epochOnly:true)}
    private func foreignInbox(epochOnly:Bool)throws {
        try withQueueFixture(citations:1) {f in
            let other="00000000-0000-0000-0000-000000006281",foreign=try SyncObjectFolder.create(at:root.appendingPathComponent("foreign-inbox"),secret:f.secret,group:epochOnly ? group:other,epoch:epochOnly ? other:epoch);defer {foreign.close()}
            let service=queueService(f.b,f.bc,f.queue,foreign),operation=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),record=try packet(operation,f.ac),members=try folderMembers(foreign)
            XCTAssertThrowsError(try queueReceive(operation,f.ac,service))
            XCTAssertEqual(try folderMembers(foreign),members);XCTAssertNil(try foreign.content(record.reference.content),"Private canonical bytes must not be retained under another group/epoch")
            XCTAssertEqual(try count(f.b,"memories"),0);XCTAssertEqual(try f.bc.journal.cursor(for:producerID),0);XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty)
        }
    }
    func testPublicationQueueWipedLifetimeRefusesSourceBeforeEncryptedRetention()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),operation=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),record=try packet(operation,f.ac)
            _=try f.b.wipeLibrary();let members=try folderMembers(f.inbox)
            XCTAssertThrowsError(try queueReceive(operation,f.ac,service))
            XCTAssertEqual(try folderMembers(f.inbox),members);XCTAssertNil(try f.inbox.content(record.reference.content),"A refused stale lifetime cannot repopulate its inbox after wipe")
        }
    }
    func testPublicationQueueWipedLifetimeRefusesDeclarationBeforeEncryptedRetention()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),reference=try XCTUnwrap(f.operations.compactMap(\.publication).first),bytes=try XCTUnwrap(f.producer.content(reference))
            _=try f.b.wipeLibrary();let members=try folderMembers(f.inbox)
            XCTAssertThrowsError(try service.retainDeclaration(bytes,reference:reference))
            XCTAssertEqual(try folderMembers(f.inbox),members);XCTAssertNil(try f.inbox.content(reference))
        }
    }
    func testPublicationQueueClosedLibraryRefusesDeclarationBeforeEncryptedRetention()throws {
        try withQueueFixture {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),reference=try XCTUnwrap(f.operations.compactMap(\.publication).first),bytes=try XCTUnwrap(f.producer.content(reference)),members=try folderMembers(f.inbox)
            try f.b.close();XCTAssertThrowsError(try service.retainDeclaration(bytes,reference:reference))
            XCTAssertEqual(try folderMembers(f.inbox),members);XCTAssertNil(try f.inbox.content(reference))
        }
    }
    func testPublicationQueueDeclarationArrivalRejectsNestedSQLiteBeforeRetentionOrMediaLock()throws {
        try withQueueFixture {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),reference=try XCTUnwrap(f.operations.compactMap(\.publication).first),bytes=try XCTUnwrap(f.producer.content(reference)),members=try folderMembers(f.inbox)
            try f.b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                XCTAssertThrowsError(try service.retainDeclaration(bytes,reference:reference))
            }}
            XCTAssertEqual(try folderMembers(f.inbox),members);XCTAssertNil(try f.inbox.content(reference))
        }
    }
    func testPublicationQueueForeignInboxRetryRefusesWithoutChangingDurableWork()throws {
        try withQueueFixture {f in
            let initial=queueService(f.b,f.bc,f.queue,f.inbox)
            for operation in f.operations {_=try queueReceive(operation,f.ac,initial)}
            let before=try f.queue.jobs(readyOnly:false),foreign=try SyncObjectFolder.create(at:root.appendingPathComponent("foreign-retry"),secret:f.secret,group:"00000000-0000-0000-0000-000000006282",epoch:epoch);defer {foreign.close()}
            let service=queueService(f.b,f.bc,f.queue,foreign),members=try folderMembers(foreign)
            XCTAssertThrowsError(try queueRetry(f.ac,service))
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.reason),before.map(\.reason));XCTAssertEqual(try folderMembers(foreign),members)
        }
    }
}
