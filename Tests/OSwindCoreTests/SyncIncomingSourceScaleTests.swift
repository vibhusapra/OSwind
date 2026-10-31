import XCTest
import Foundation
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    /// One warm authored run per size. Includes local revision/body reads,
    /// typed journal receipt and native projection in128-record transactions.
    /// Excludes transport, policy inference, models, media, power and ranking.
    func testOwnedIncomingSourceProjectionAtBoundedScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_INCOMING_SOURCE_SCALE_OUTPUT"] else {throw XCTSkip("Explicit owned incoming-source scale output required")}
        let fm=FileManager.default,base=URL(fileURLWithPath:path,isDirectory:true)
        guard base.path==path,base.resolvingSymlinksInPath().path==path,base.standardizedFileURL.path==path,fm.fileExists(atPath:base.deletingLastPathComponent().path),!fm.fileExists(atPath:path) else {throw OSwindError.invalid("Incoming-source scale requires a fresh absolute nonsymlink output")}
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored incoming source scale v1".utf8).write(to:base.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        let previousRoot=root;defer {root=previousRoot};var reports=[[String:Any]]()
        for size in [1000,10000] {
            let folder=base.appendingPathComponent("n\(size)");try fm.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);root=folder
            let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
            let padding=String(repeating:"x",count:1024),template=Memory(id:"template",timestamp:now,kind:.note,app:"Owned incoming scale",title:"Incoming source",text:"template"),payload=try SyncProtocolLimits.encode(template),load=ProcessInfo.processInfo.systemUptime
            try a.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                let row=try db.statement("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
                INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload)
                SELECT printf('incoming-%08d',x),1700000000,'note','Owned incoming scale','Incoming source',NULL,'Owned incoming source '||x||' '||?,0,
                       CAST(json_set(CAST(? AS TEXT),'$.id',printf('incoming-%08d',x),'$.text','Owned incoming source '||x||' '||?) AS BLOB) FROM n
                """);defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(size));db.bind(row,2,padding);payload.withUnsafeBytes {_=sqlite3_bind_blob(row,3,$0.baseAddress,Int32(payload.count),db.transient)};db.bind(row,4,padding);try db.done(row)
            }}
            let loadSeconds=ProcessInfo.processInfo.systemUptime-load,prepare=ProcessInfo.processInfo.systemUptime;try drain(a,ac);let prepareSeconds=ProcessInfo.processInfo.systemUptime-prepare
            let lease=try b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            var cursor:Int64=0,received=0,batches=[[String:Any]]();let start=ProcessInfo.processInfo.systemUptime
            while true {
                let began=ProcessInfo.processInfo.systemUptime,operations=try ac.journal.outbox(after:cursor,limit:128);if operations.isEmpty {break}
                let packets=try operations.map {try packet($0,ac)}
                try b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                    for (operation,record) in zip(operations,packets) {
                        let result=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("Plain scale source has no dependency")})}
                        XCTAssertEqual(result.applied,1)
                    }
                }}
                cursor=operations.last!.dot.counter;received+=operations.count;batches.append(["objects":operations.count,"seconds":ProcessInfo.processInfo.systemUptime-began])
            }
            let incomingSeconds=ProcessInfo.processInfo.systemUptime-start;lease.release();XCTAssertEqual(received,size);XCTAssertEqual(try count(b,"memories"),size);XCTAssertEqual(try count(b,"personal_sync_versions"),size);XCTAssertTrue(try bc.journal.outbox().isEmpty);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
            var chains=[[String:Any]]()
            for index in 1...10 {
                let producerLocal=String(format:"incoming-%08d",index),identity=try ac.catalog.localIdentity(.source,primary:[.text(Data(producerLocal.utf8))]),local="peer-"+(try identity.key.digest),source=try XCTUnwrap(b.get(local))
                let one=try b.saveRecap(.init(text:"Owned chain \(index) first",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0),title:"First recap"),two=try b.saveRecap(.init(text:"Owned chain \(index) second",sources:[.init(memory:one,score:1,match:"owned")],provider:"owned",duration:0),title:"Second recap"),chat=try b.createChat(title:"Owned exact chain")
                _=try b.appendChatTurn(sessionID:chat.id,question:"Original source?",answer:.init(text:"Original [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0))
                _=try b.appendChatTurn(sessionID:chat.id,question:"Original second recap?",answer:.init(text:"Second [1]",sources:[.init(memory:two,score:1,match:"owned")],provider:"owned",duration:0))
                chains.append(["index":index,"source":local,"recapOne":one.id,"recapTwo":two.id,"conversation":chat.id,"oldText":source.text])
            }
            try drain(b,bc);let before=try bc.journal.outbox(),versions=try count(b,"personal_sync_versions")
            for index in 1...10 {
                var source=try XCTUnwrap(a.get(String(format:"incoming-%08d",index)));source.text="Owned newer incoming source \(index) "+padding;try a.insert(source)
            }
            try drain(a,ac);let updateLease=try b.mediaWriteLease();defer {updateLease.release()};var changed=0;let update=ProcessInfo.processInfo.systemUptime
            while true {
                let operations=try ac.journal.outbox(after:cursor,limit:128);if operations.isEmpty {break}
                for operation in operations {
                    let record=try packet(operation,ac),result=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:updateLease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
                    XCTAssertEqual(result.applied,1);changed+=1
                }
                cursor=operations.last!.dot.counter
            }
            let updateSeconds=ProcessInfo.processInfo.systemUptime-update;XCTAssertEqual(changed,10);XCTAssertEqual(try bc.journal.outbox(),before);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertEqual(try count(b,"historical_evidence"),30);XCTAssertEqual(try count(b,"personal_sync_versions"),versions+10)
            for chain in chains {
                let index=chain["index"] as! Int,source=chain["source"] as! String,one=chain["recapOne"] as! String,two=chain["recapTwo"] as! String
                XCTAssertEqual(try b.get(source)?.text,"Owned newer incoming source \(index) "+padding)
                XCTAssertEqual(try b.recapEvidence(one).first?.memory.text,chain["oldText"] as? String);XCTAssertEqual(try b.recapEvidence(two).first?.memory.text,"Owned chain \(index) first")
                XCTAssertEqual(try b.chatTurns(chain["conversation"] as! String).count,2)
            }
            let report:[String:Any]=["count":size,"librarySchema":MemoryStore.schemaVersion,"loadSeconds":loadSeconds,"outgoingPreparationSeconds":prepareSeconds,"incomingSeconds":incomingSeconds,"incomingObjects":received,"batchSize":128,"batches":batches,"updatedObjects":changed,"citedUpdateSeconds":updateSeconds,"chains":chains,"receiverOutbox":before.count,"receiverVersions":versions+10,"sourceBodyPaddingBytes":1024]
            updateLease.release();try a.close();try b.close();try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("report.json"));reports.append(report)
            print("INCOMING_SOURCE_SCALE rows=\(size) incomingSeconds=\(incomingSeconds) citedUpdateSeconds=\(updateSeconds) exactOldOriginals=30 noEcho=true")
        }
        try JSONSerialization.data(withJSONObject:reports,options:[.sortedKeys,.prettyPrinted]).write(to:base.appendingPathComponent("report.json"))
    }
}
