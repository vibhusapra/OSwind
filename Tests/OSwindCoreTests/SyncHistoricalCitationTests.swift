import XCTest
import CSQLite
@testable import OSwindCore

/// Owned producer/receiver regression for the next incoming adapter. The
/// retained development-v3 snapshot demonstrates the insufficient canonical-only
/// fixture. This version exercises the real typed incoming conversation writer.
final class SyncHistoricalCitationTests:XCTestCase {
    var root:URL!
    var retainFixture=false
    let group="00000000-0000-0000-0000-000000001002",epoch="00000000-0000-0000-0000-000000001003"
    let producerID="00000000-0000-0000-0000-000000001001",receiverID="00000000-0000-0000-0000-000000001004"
    let now=Date(timeIntervalSince1970:1700000000)
    override func setUpWithError()throws {
        let fm=FileManager.default
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_HISTORICAL_CITATION_REPRO_ROOT"] {
            root=URL(fileURLWithPath:path,isDirectory:true)
            guard root.path==path,root.standardizedFileURL.path==path,root.resolvingSymlinksInPath().path==path,!fm.fileExists(atPath:path),fm.fileExists(atPath:root.deletingLastPathComponent().path) else {throw OSwindError.invalid("Historical citation fixture requires a fresh absolute nonsymlink directory")}
            retainFixture=true
        }else {root=fm.temporaryDirectory.appendingPathComponent("owned-historical-citation-"+UUID().uuidString)}
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data("OSwind authored historical citation regression v1".utf8).write(to:root.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
    }
    override func tearDownWithError()throws {if !retainFixture {try FileManager.default.removeItem(at:root)}}
    func endpoint(_ directory:String,_ replica:String)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:root.appendingPathComponent(directory))
        let cache=try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        return(store,cache)
    }
    func drain(_ cache:SyncVersionStore)throws {
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:cache.catalog),cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        for _ in 0..<80 {if try processor.step() == .idle {return}}
        throw OSwindError.invalid("Owned outgoing fixture did not finish")
    }
    func packet(_ revision:SyncRevision,_ cache:SyncVersionStore)throws->SyncPortableRecord {
        let content=try XCTUnwrap(revision.content),db=cache.database,row=try db.statement("SELECT body FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)}
        db.bind(row,1,revision.key.digest);db.bind(row,2,content.sha256)
        guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0),sqlite3_column_bytes(row,0)>0 else {throw db.error()}
        let value=try SyncPortableRecord.decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
        XCTAssertEqual(try value.identity.key,revision.key);XCTAssertEqual(try value.reference.content,content);return value
    }
    func blob(_ db:RoutineDatabase,_ row:OpaquePointer,_ index:Int32,_ data:Data) {data.withUnsafeBytes {_ = sqlite3_bind_blob(row,index,$0.baseAddress,Int32(data.count),db.transient)}}
    func testConcurrentOriginalCitationSurvivesCanonicalReadAndQuietBackupRestore()throws {
        let (producer,a)=try endpoint("producer",producerID),(receiver,b)=try endpoint("receiver",receiverID)
        defer {try? producer.close();try? receiver.close()}
        try b.journal.allowPeer(producerID)
        let originalText="Original Alice owns Orion.",currentText="Receiver current text"
        try producer.insert(Memory(id:"authored-source",timestamp:now,kind:.note,app:"Owned",title:"Original",text:originalText));try drain(a)
        let initial=try XCTUnwrap(a.journal.outbox().first),original=try packet(initial,a),reference=try original.reference
        _=try b.journal.receive(initial,contentAvailable:{_ in true}) {_ in
            try b.catalog.applyPeer(original.identity,primary:[.text(Data("receiver-source".utf8))]) {
                guard case .source(let body)=original.body else {throw OSwindError.invalid("Expected authored source")}
                try receiver.insert(body.projectedMemory(id:"receiver-source",paths:[:]){_ in throw OSwindError.invalid("No owned recap")})
            };_=try b.retain(original,admit:{_ in})
        }
        var edited=try XCTUnwrap(receiver.get("receiver-source"));edited.text=currentText;try receiver.insert(edited);try drain(b)
        let localOperations=try b.journal.outbox()
        let chat=try producer.createChat(title:"Owned historical citation")
        _=try producer.appendChatTurn(sessionID:chat.id,question:"Who originally owned Orion?",answer:.init(text:"Alice owns Orion [1].",sources:[.init(memory:try XCTUnwrap(producer.get("authored-source")),score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(a)
        var applied=Set<SyncCanonicalTable>()
        let admission=try receiver.mediaWriteLease();defer {admission.release()}
        let writer=SyncIncomingConversationWriter(library:receiver,cache:b,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in},newID:{identity in identity.table == .conversation ? "receiver-chat":"receiver-turn"})
        for revision in try a.journal.outbox().dropFirst() {
            let value=try packet(revision,a)
            if value.identity.table == .conversation {
                let wrong=try producer.mediaWriteLease();defer {wrong.release()}
                XCTAssertThrowsError(try b.journal.receive(revision,contentAvailable:{_ in true}) {_ in _=try writer.apply(value,admission:wrong,fetchExactSource:{_ in original})})
                let released=try receiver.mediaWriteLease();released.release()
                XCTAssertThrowsError(try b.journal.receive(revision,contentAvailable:{_ in true}) {_ in _=try writer.apply(value,admission:released,fetchExactSource:{_ in original})})
            }
            _=try b.journal.receive(revision,contentAvailable:{_ in true}) {_ in
                _=try writer.apply(value,admission:admission,fetchExactSource:{requested in
                    guard requested==reference else {throw OSwindError.invalid("Unexpected requested original")};return original
                })
                _=try b.retain(value,admit:{_ in});applied.insert(value.identity.table)
            }
        }
        XCTAssertEqual(applied,[.conversation,.turn,.conversationCitation,.evidencePin])
        XCTAssertEqual(try receiver.get("receiver-source")?.text,currentText);XCTAssertEqual(try receiver.stats().count,1);XCTAssertEqual(try b.journal.outbox(),localOperations)
        let live=try XCTUnwrap(receiver.chatTurns("receiver-chat").first?.answer.sources.first?.memory)
        let admittedOriginal=try receiver.withRoutineDatabase {try HistoricalEvidenceStore(database:$0).read(XCTUnwrap(live.originalEvidence).handle,sourceID:"receiver-source",verifyMedia:{_,_,_ in})}
        XCTAssertEqual(try admittedOriginal.reference,reference);XCTAssertEqual(admittedOriginal.memory.text,originalText)
        let archive=root.appendingPathComponent("history.oswindbackup"),restored=root.appendingPathComponent("restored")
        _=try LibraryBackup.create(store:receiver,destination:archive);_=try LibraryBackup.restore(archive,to:restored)
        let copy=try MemoryStore(root:restored);defer {try? copy.close()}
        let copied=try XCTUnwrap(copy.chatTurns("receiver-chat").first?.answer.sources.first?.memory)
        XCTAssertEqual(try copy.get("receiver-source")?.text,currentText)
        if retainFixture {
            let result:[String:Any]=["expectedOriginal":originalText,"canonicalCurrent":currentText,"liveCitation":live.text,"restoredCitation":copied.text,"admittedExactOriginal":admittedOriginal.memory.text,"originalSHA256":reference.content.sha256,"wireGraphTables":applied.map(\.rawValue).sorted(),"receiverOutboxUnchanged":try b.journal.outbox()==localOperations,"scope":"Owned two-library actual outgoing/journal graph and typed incoming conversation writer, with independent archival data. Not an enrolled/background incoming sync service."]
            try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("observation.json"),options:.withoutOverwriting)
        }
        XCTAssertEqual(live.text,originalText,"Historical citation must read its admitted original instead of current canonical text")
        XCTAssertNotNil(live.originalEvidence,"Historical evidence must remain read-only")
        XCTAssertEqual(copied.text,originalText,"Quiet restore must preserve actual historical evidence without substituting current text")
        XCTAssertNotNil(copied.originalEvidence,"Restored historical evidence must remain read-only")
    }
}
