import XCTest
@testable import OSwindCore

extension SyncOutgoingTests {
    func testSignedServiceReopensPartialThirteenKindGraphAndPreservesOriginalCitations()throws {
        try seedGraph()
        let expected=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {($0.rawValue,try serviceCount(store,$0.rawValue))})
        let owner=try SyncPendingJoin(name:"Owned graph sender"),join=try SyncPendingJoin(name:"Owned graph receiver"),authority=try SyncGroupAuthority(owner:owner.request).admitting(join.request)
        let first=try owner.accept(authority.response(to:owner.request),expectedRootFingerprint:authority.fingerprint)
        let second=try join.accept(authority.response(to:join.request),expectedRootFingerprint:authority.fingerprint)
        let group=first.certificate.body.group,epoch=first.certificate.body.epoch
        let shared=root.deletingLastPathComponent().appendingPathComponent("owned-signed-graph-"+UUID().uuidString)
        let destination=root.deletingLastPathComponent().appendingPathComponent("owned-signed-native-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:shared);try? FileManager.default.removeItem(at:destination)}
        var receiver=try MemoryStore(root:destination)
        var aFolder=try first.createTransport(at:shared),bFolder=try second.openTransport(at:shared)
        let aPath=store.root.appendingPathComponent("images/signed-inbox"),bPath=receiver.root.appendingPathComponent("images/signed-inbox")
        var aInbox=try first.createPrivateInbox(at:aPath),bInbox=try second.createPrivateInbox(at:bPath)
        var sender:SyncLibraryService?,receiverService:SyncLibraryService?
        defer {try? sender?.stop();try? receiverService?.stop();aInbox.close();bInbox.close();aFolder.close();bFolder.close();try? receiver.close()}
        sender=try .install(library:store,replica:first.replica,group:group,epoch:epoch,peers:[second.replica],transport:aFolder,inbox:aInbox)
        receiverService=try .install(library:receiver,replica:second.replica,group:group,epoch:epoch,peers:[first.replica],transport:bFolder,inbox:bInbox)
        for _ in 0..<40 {_=try serviceReady(XCTUnwrap(sender),limit:1)}
        _=try serviceReady(XCTUnwrap(receiverService),limit:1)
        let partial=try XCTUnwrap(receiverService!.cache.journal.cursor(for:first.replica))
        XCTAssertEqual(partial,1);XCTAssertEqual(try aFolder.serviceHead(replica:first.replica)?.through,21)
        try sender!.stop();try receiverService!.stop();try store.close();try receiver.close()
        aInbox.close();bInbox.close();aFolder.close();bFolder.close()
        store=try MemoryStore(root:root);receiver=try MemoryStore(root:destination)
        aFolder=try first.openTransport(at:shared);bFolder=try second.openTransport(at:shared)
        aInbox=try first.openPrivateInbox(at:aPath);bInbox=try second.openPrivateInbox(at:bPath)
        sender=try .install(library:store,replica:first.replica,group:group,epoch:epoch,peers:[second.replica],transport:aFolder,inbox:aInbox)
        receiverService=try .install(library:receiver,replica:second.replica,group:group,epoch:epoch,peers:[first.replica],transport:bFolder,inbox:bInbox)
        XCTAssertEqual(try receiverService!.cache.journal.cursor(for:first.replica),partial)
        for _ in 0..<40 {_=try serviceReady(XCTUnwrap(sender),limit:2);_=try serviceReady(XCTUnwrap(receiverService),limit:2)}
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try serviceCount(receiver,table.rawValue),expected[table.rawValue],table.rawValue)}
        XCTAssertEqual(try receiverService!.cache.journal.cursor(for:first.replica),21)
        XCTAssertEqual(try receiverService!.cache.journal.outbox().count,0)
        XCTAssertEqual(try serviceCount(receiver,"personal_sync_publication_bindings"),1)
        XCTAssertEqual(try serviceCount(receiver,"personal_sync_publication_jobs"),0)
        XCTAssertEqual(try serviceCount(receiver,"personal_sync_changes"),0)
        if let outputRoot=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_SERVICE_ROOT"] {
            let output=URL(fileURLWithPath:outputRoot,isDirectory:true).appendingPathComponent("signed-reopened-all13-"+UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try snapshotNativeCollectionBefore(store,to:output.appendingPathComponent("producer.sqlite"))
            try snapshotNativeCollectionBefore(receiver,to:output.appendingPathComponent("receiver.sqlite"))
            let receipt:[String:Any]=["tables":expected,"producerReplica":first.replica,"partialCursor":partial,"finalCursor":21,"peerOutbox":0,"publicationJobs":0,"publicationBindings":1,"transport":"space-v3","membershipRevision":2]
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
        }
    }
}
