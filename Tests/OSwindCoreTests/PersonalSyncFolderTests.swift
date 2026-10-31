import XCTest
import Darwin
import CSQLite
@testable import OSwindCore

private final class SyncFolderFailures:@unchecked Sendable {
    let lock=NSLock();var count=0
    func append() {lock.lock();count+=1;lock.unlock()}
}
final class PersonalSyncFolderTests:XCTestCase {
    let a="00000000-0000-0000-0000-000000000001",b="00000000-0000-0000-0000-000000000002"
    let group="00000000-0000-0000-0000-000000000003",epoch="00000000-0000-0000-0000-000000000004"
    var root:URL!,space:URL!,secret:SyncGroupSecret!,folder:SyncObjectFolder!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-sync-folder-"+UUID().uuidString);try Paths.ensure(root)
        space=root.appendingPathComponent("space");secret=SyncGroupSecret();folder=try .create(at:space,secret:secret,group:group,epoch:epoch)
    }
    override func tearDownWithError()throws {folder?.close();folder=nil;try FileManager.default.removeItem(at:root)}
    func put(_ data:Data,actor:String?=nil,counter:Int64=1)throws->SyncRevision {
        let reference=try SyncContentReference(data:data)
        return try SyncRevision(key:.make(kind:.source,identity:Data("owned source".utf8)),dot:.init(replica:actor ?? a,counter:counter),context:.empty,mutation:.put,content:reference)
    }
    func objectFiles()throws->[URL] {
        let enumerator=try XCTUnwrap(FileManager.default.enumerator(at:space,includingPropertiesForKeys:[.isRegularFileKey]))
        return enumerator.compactMap {$0 as? URL}.filter {$0.lastPathComponent.utf8.count==64}
    }
    func testSpaceCannotBeAdoptedWithWrongKeyEpochOrExistingDirectory()throws {
        XCTAssertThrowsError(try SyncObjectFolder.open(at:space,secret:SyncGroupSecret(),group:group,epoch:epoch))
        XCTAssertThrowsError(try SyncObjectFolder.open(at:space,secret:secret,group:group,epoch:b))
        XCTAssertThrowsError(try SyncObjectFolder.create(at:space,secret:secret,group:group,epoch:epoch))
        let reopened=try SyncObjectFolder.open(at:space,secret:secret,group:group,epoch:epoch);reopened.close()
    }
    func testChunkedAndEmptyContentRoundTripsExactly()throws {
        for bytes in [Data(),Data(repeating:42,count:SyncCipherContext.maximumPlaintextBytes*2+197)] {
            let reference=try SyncContentReference(data:bytes);try folder.publishContent(bytes,reference:reference)
            XCTAssertEqual(try folder.content(reference),bytes)
        }
        XCTAssertThrowsError(try folder.publishContent(Data("changed".utf8),reference:.init(data:Data("original".utf8))))
    }
    func testOperationWaitsForCompleteContentAndIsIdempotent()throws {
        let bytes=Data("private authored original note".utf8),revision=try put(Data("private authored original note".utf8))
        XCTAssertThrowsError(try folder.publishRevision(revision));XCTAssertNil(try folder.revision(replica:a,sequence:1))
        try folder.publishContent(bytes,reference:try XCTUnwrap(revision.content));try folder.publishRevision(revision)
        let before=try Dictionary(uniqueKeysWithValues:objectFiles().map {($0.path,try Data(contentsOf:$0))})
        try folder.publishContent(bytes,reference:try XCTUnwrap(revision.content));try folder.publishRevision(revision)
        XCTAssertEqual(try folder.revision(replica:a,sequence:1),revision)
        XCTAssertEqual(try Dictionary(uniqueKeysWithValues:objectFiles().map {($0.path,try Data(contentsOf:$0))}),before)
        for file in try objectFiles() {XCTAssertNil(try Data(contentsOf:file).range(of:bytes));XCTAssertTrue(file.lastPathComponent.utf8.allSatisfy {(48...57).contains($0)||(97...102).contains($0)})}
    }
    func testImmutableSequenceForkCannotOverwriteFirstOperation()throws {
        let first=Data("first".utf8),second=Data("second".utf8),one=try put(Data("first".utf8)),two=try put(Data("second".utf8))
        try folder.publishContent(first,reference:try XCTUnwrap(one.content));try folder.publishRevision(one)
        try folder.publishContent(second,reference:try XCTUnwrap(two.content))
        XCTAssertThrowsError(try folder.publishRevision(two));XCTAssertEqual(try folder.revision(replica:a,sequence:1),one)
    }
    func testCorruptionAndSymlinkObjectsNeverReturnPlaintext()throws {
        let bytes=Data("authored private payload".utf8),reference=try SyncContentReference(data:Data("authored private payload".utf8))
        try folder.publishContent(bytes,reference:reference)
        let file=try XCTUnwrap(objectFiles().first);try Data("corrupt encrypted object".utf8).write(to:file)
        XCTAssertThrowsError(try folder.content(reference))
        let outside=root.appendingPathComponent("outside");try bytes.write(to:outside)
        try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        XCTAssertThrowsError(try folder.content(reference));XCTAssertEqual(try Data(contentsOf:outside),bytes)
    }
    func testRootReplacementAndCloseCannotRedirectOrContinueIO()throws {
        let original=root.appendingPathComponent("retained");try FileManager.default.moveItem(at:space,to:original);try Paths.ensure(space)
        let bytes=Data("authored".utf8),reference=try SyncContentReference(data:Data("authored".utf8))
        XCTAssertThrowsError(try folder.publishContent(bytes,reference:reference));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:space.path).isEmpty)
        folder.close();XCTAssertTrue(folder.isClosed);XCTAssertThrowsError(try folder.content(reference))
    }
    func testConcurrentPublishersKeepOneCompleteImmutableObject()throws {
        let bytes=Data(repeating:21,count:8192),reference=try SyncContentReference(data:Data(repeating:21,count:8192))
        let failures=SyncFolderFailures(),root=space!,secret=secret!,group=self.group,epoch=self.epoch
        DispatchQueue.concurrentPerform(iterations:8) {_ in
            do {let writer=try SyncObjectFolder.open(at:root,secret:secret,group:group,epoch:epoch);defer {writer.close()};try writer.publishContent(bytes,reference:reference)}catch {failures.append()}
        }
        XCTAssertEqual(failures.count,0);XCTAssertEqual(try folder.content(reference),bytes);XCTAssertEqual(try objectFiles().count,1)
    }
    func testTwoOwnedLibrariesExchangeBothWaysResolveConflictsAndRejectOfflineResurrection()throws {
        let first=try MemoryStore(root:root.appendingPathComponent("first")),second=try MemoryStore(root:root.appendingPathComponent("second"))
        defer {try? first.close();try? second.close()}
        func initialize(_ store:MemoryStore,_ replica:String)throws {
            try store.withRoutineDatabase {db in let journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch);try journal.allowPeer(replica==a ? b:a)}
        }
        try initialize(first,a);try initialize(second,b)
        let original=Memory(id:"owned-peer-source",text:"Authored source survives encrypted peer exchange")
        let object=try SyncObjectKey.make(kind:.source,identity:Data((a+"/owned-peer-source").utf8))
        let reply=Memory(id:"owned-peer-reply",text:"Second peer has its own authored source")
        let replyKey=try SyncObjectKey.make(kind:.source,identity:Data((b+"/owned-peer-reply").utf8))
        let localIDs=[object:original.id,replyKey:reply.id]
        func produce(_ store:MemoryStore,_ replica:String,_ memory:Memory,_ key:SyncObjectKey,resolving:Set<SyncDot>?=nil)throws->SyncRevision {
            let data=try SyncProtocolLimits.encode(memory),reference=try SyncContentReference(data:SyncProtocolLimits.encode(memory))
            let revision=try store.withRoutineDatabase {db in
                let journal=try SyncJournal(database:db,replica:replica,group:group,epoch:epoch)
                if let resolving {return try journal.resolve(key:key,expectedHeads:resolving,content:reference) {_ in try store.insert(memory)}}
                return try journal.put(key:key,content:reference) {_ in try store.insert(memory)}
            }
            // Only committed, authored data is published. Real adapters also
            // need current privacy/egress fences before publishing queued data.
            try folder.publishContent(data,reference:reference);try folder.publishRevision(revision);return revision
        }
        func deliver(_ store:MemoryStore,_ replica:String,_ revision:SyncRevision)throws {
            let packet=try XCTUnwrap(folder.revision(replica:revision.dot.replica,sequence:revision.dot.counter))
            let before=try store.withRoutineDatabase {try SyncJournal(database:$0,replica:replica,group:group,epoch:epoch).state(for:packet.key)}
            var prepared=[String:Data]()
            if !before.isDeleted {
                for reference in before.heads.compactMap(\.content)+[packet.content].compactMap({$0}) {
                    if let data=try folder.content(reference) {XCTAssertTrue(reference.matches(data));prepared[reference.sha256]=data}
                }
            }
            try store.withRoutineDatabase {db in
                let journal=try SyncJournal(database:db,replica:replica,group:group,epoch:epoch)
                try journal.receive(packet,contentAvailable:{reference in prepared[reference.sha256].map {reference.matches($0)} ?? false}) {change in
                    let identifier=try XCTUnwrap(localIDs[change.after.key])
                    if change.after.isDeleted {
                        // This fixture contains text notes only. Full adapters
                        // must use the existing coordinated media erasure path.
                        let row=try db.statement("DELETE FROM memories WHERE id=?")
                        defer {sqlite3_finalize(row)};db.bind(row,1,identifier);try db.done(row)
                    } else {
                        let reference=try XCTUnwrap(change.after.preferred?.content),data=try XCTUnwrap(prepared[reference.sha256])
                        XCTAssertTrue(reference.matches(data))
                        let memory=try JSONDecoder().decode(Memory.self,from:data);XCTAssertEqual(memory.id,identifier)
                        try store.insert(memory)
                    }
                }
            }
        }
        let one=try produce(first,a,original,object);try deliver(second,b,one)
        let two=try produce(second,b,reply,replyKey);try deliver(first,a,two)
        XCTAssertEqual(try first.get(reply.id)?.text,reply.text);XCTAssertEqual(try second.get(original.id)?.text,original.text)
        var alpha=original;alpha.text="First peer offline edit"
        var beta=original;beta.text="Second peer concurrent edit"
        let editA=try produce(first,a,alpha,object),editB=try produce(second,b,beta,object)
        try deliver(second,b,editA);try deliver(first,a,editB)
        let heads=try first.withRoutineDatabase {try SyncJournal(database:$0,replica:a,group:group,epoch:epoch).state(for:object)}
        XCTAssertTrue(heads.isConflicted);XCTAssertEqual(heads.heads.count,2)
        XCTAssertEqual(try first.get(original.id)?.text,try second.get(original.id)?.text)
        var resolved=original;resolved.text="Explicitly reviewed merged source SyncResolutionUniqueLeaf9q31"
        let resolution=try produce(first,a,resolved,object,resolving:Set(heads.heads.map(\.dot)));try deliver(second,b,resolution)
        XCTAssertEqual(try second.get(original.id)?.text,resolved.text)
        XCTAssertEqual(try first.search(SearchFilter(query:"SyncResolutionUniqueLeaf9q31"),mode:.keyword).map { $0.memory.id },[original.id])
        XCTAssertEqual(try second.search(SearchFilter(query:"SyncResolutionUniqueLeaf9q31"),mode:.keyword).map { $0.memory.id },[original.id])
        var offline=original;offline.text="Offline edit that must not resurrect a deleted source"
        let late=try produce(second,b,offline,object)
        let deletion=try first.withRoutineDatabase {db in
            try SyncJournal(database:db,replica:a,group:group,epoch:epoch).delete(key:object) {_ in
                let row=try db.statement("DELETE FROM memories WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,original.id);try db.done(row)
            }
        }
        try folder.publishRevision(deletion);try deliver(second,b,deletion);try deliver(first,a,late)
        XCTAssertNil(try first.get(original.id));XCTAssertNil(try second.get(original.id))
        XCTAssertTrue(try first.search(SearchFilter(query:"SyncResolutionUniqueLeaf9q31"),mode:.keyword).isEmpty)
        XCTAssertTrue(try second.search(SearchFilter(query:"SyncResolutionUniqueLeaf9q31"),mode:.keyword).isEmpty)
        try deliver(second,b,one);XCTAssertNil(try second.get(original.id))
        XCTAssertEqual(try first.get(reply.id)?.text,reply.text);XCTAssertEqual(try second.get(reply.id)?.text,reply.text)
        let finalA=try first.withRoutineDatabase {try SyncJournal(database:$0,replica:a,group:group,epoch:epoch).state(for:object)}
        let finalB=try second.withRoutineDatabase {try SyncJournal(database:$0,replica:b,group:group,epoch:epoch).state(for:object)}
        XCTAssertTrue(finalA.isDeleted);XCTAssertEqual(finalA,finalB)
    }

}
