import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    func testExternallyAnchoredServiceReopensPartialThirteenKindGraphWithoutEcho()throws {
        try seedGraph()
        let expected=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {($0.rawValue,try serviceCount(store,$0.rawValue))})
        let container=root.deletingLastPathComponent().appendingPathComponent("owned-anchored-all13-"+UUID().uuidString)
        try Paths.ensure(container);defer {try? FileManager.default.removeItem(at:container)}
        let destination=container.appendingPathComponent("receiver"),shared=container.appendingPathComponent("shared"),state=container.appendingPathComponent("state")
        let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64)),backend=DeliveryTestStorage()
        var receiver=try MemoryStore(root:destination)
        var owner=try PersonalSyncPairing(store:store,stateRoot:state,machine:machine,storage:backend),joiner=try PersonalSyncPairing(store:receiver,stateRoot:state,machine:machine,storage:backend)
        var sender:SyncLibraryService?,incoming:SyncLibraryService?
        defer {for service in [sender,incoming].compactMap({$0}) {try? service.stop();service.inbox.close();service.transport.close()};owner.close();joiner.close();try? receiver.close()}
        _=try owner.createGroup(deviceName:"Owned graph sender")
        let request=try XCTUnwrap(joiner.requestJoin(deviceName:"Owned graph receiver").request)
        let response=try owner.approve(owner.reviewRequest(request));_=try joiner.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!)
        sender=try owner.prepareAnchoredService(shared:shared,createShared:true)
        incoming=try joiner.prepareAnchoredService(shared:shared,createShared:false)
        try sender!.installNativeWriterAdmission();try incoming!.installNativeWriterAdmission()
        let producer=sender!.cache.journal.replica
        for _ in 0..<40 {_=try serviceReady(sender!,limit:1)}
        _=try serviceReady(incoming!,limit:1)
        XCTAssertEqual(try incoming!.cache.journal.cursor(for:producer),1)
        XCTAssertEqual(try sender!.transport.serviceHead(replica:producer)?.through,21)
        for service in [sender,incoming].compactMap({$0}) {try service.stop();service.inbox.close();service.transport.close()}
        owner.close();joiner.close();try store.close();try receiver.close()
        let nativeEnvironment=SyncNativeWriterEnvironment(stateRoot:state,machine:machine,storage:{_ in backend})
        store=try MemoryStore(root:root,recoveryReadOnly:false,nativeWriterEnvironment:nativeEnvironment);receiver=try MemoryStore(root:destination,recoveryReadOnly:false,nativeWriterEnvironment:nativeEnvironment)
        owner=try PersonalSyncPairing(store:store,stateRoot:state,machine:machine,storage:backend);joiner=try PersonalSyncPairing(store:receiver,stateRoot:state,machine:machine,storage:backend)
        sender=try owner.prepareAnchoredService(shared:shared,createShared:false);incoming=try joiner.prepareAnchoredService(shared:shared,createShared:false)
        for _ in 0..<40 {_=try serviceReady(sender!,limit:2);_=try serviceReady(incoming!,limit:2)}
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try serviceCount(receiver,table.rawValue),expected[table.rawValue],table.rawValue)}
        for library in [store!,receiver] {XCTAssertEqual(try library.withRoutineDatabase {try $0.eraseCount("PRAGMA user_version")},35)}
        XCTAssertEqual(try incoming!.cache.journal.cursor(for:producer),21)
        XCTAssertEqual(try incoming!.cache.journal.outbox().count,0)
        XCTAssertEqual(try serviceCount(receiver,"personal_sync_publication_bindings"),1)
        let expectedBodies=try anchoredWireBodies(store),receivedBodies=try anchoredWireBodies(receiver)
        XCTAssertEqual(expectedBodies.count,21);XCTAssertEqual(receivedBodies,expectedBodies)
        // Imported immutable originals are intentionally stored separately from
        // the producer's live native rows. Verify exact wire bytes, not equal
        // historical-table counts on those two different projections.
        try receiver.withRoutineDatabase {db in
            let row=try db.statement("SELECT object_digest,content_sha,body FROM historical_evidence");defer {sqlite3_finalize(row)}
            var count=0
            while sqlite3_step(row)==SQLITE_ROW {
                count+=1;let bytes=Data(bytes:sqlite3_column_blob(row,2)!,count:Int(sqlite3_column_bytes(row,2)))
                XCTAssertEqual(bytes,expectedBodies[db.text(row,0)+":"+db.text(row,1)])
            }
            XCTAssertEqual(count,2)
        }
        if let outputRoot=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_ANCHORED_FIXTURE_ROOT"] {
            let output=URL(fileURLWithPath:outputRoot,isDirectory:true).appendingPathComponent("reopened-all13-"+UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try snapshotNativeCollectionBefore(store,to:output.appendingPathComponent("producer.sqlite"))
            try snapshotNativeCollectionBefore(receiver,to:output.appendingPathComponent("receiver.sqlite"))
            var publicFloors=[[String:Any]]()
            for (id,bytes) in backend.values {
                guard let saved=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],saved["format"] as? String=="OSwind.sync.delivery-anchor",let token=saved["token"] as? [String:Any] else {continue}
                publicFloors.append(["id":id,"token":token])
            }
            XCTAssertEqual(publicFloors.count,2)
            let receipt:[String:Any]=["nativeWriterSchema":35,"tables":expected,"producerReplica":producer,"partialCursor":1,"finalCursor":21,"wireBodies":21,"receiverOutbox":0,"nativeOriginals":2,"externalCheckpoints":publicFloors,"checkpointBackend":"owned deterministic test storage; actual Keychain is tested separately","privateKeysExported":false]
            try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
        }
    }
    private func anchoredWireBodies(_ store:MemoryStore)throws->[String:Data] {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT object_digest,content_sha,body FROM personal_sync_versions");defer {sqlite3_finalize(row)}
            var result=[String:Data]()
            while sqlite3_step(row)==SQLITE_ROW {
                let bytes=Data(bytes:sqlite3_column_blob(row,2)!,count:Int(sqlite3_column_bytes(row,2)))
                XCTAssertEqual(SyncProtocolLimits.hex(bytes),db.text(row,1))
                _=try SyncPortableRecord.decode(bytes)
                result[db.text(row,0)+":"+db.text(row,1)]=bytes
            };return result
        }

    }
}
