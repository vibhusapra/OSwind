import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Real outgoing records/journal receipt and native incoming projection, using
/// two owned libraries. No background service, peer enrollment or paid provider.
final class SyncIncomingSourceTests:XCTestCase {
    var root:URL!,keep=false
    let group="00000000-0000-0000-0000-000000006102",epoch="00000000-0000-0000-0000-000000006103"
    let producerID="00000000-0000-0000-0000-000000006101",receiverID="00000000-0000-0000-0000-000000006104"
    let now=Date(timeIntervalSince1970:1700000000)
    override func setUpWithError()throws {
        let fm=FileManager.default
        if let path=ProcessInfo.processInfo.environment["OSWIND_INCOMING_SOURCE_CRASH_ROOT"],let nonce=ProcessInfo.processInfo.environment["OSWIND_INCOMING_SOURCE_CRASH_NONCE"] {
            let expected=FileManager.default.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce)
            let candidate=URL(fileURLWithPath:path,isDirectory:true)
            guard UUID(uuidString:nonce)?.uuidString==nonce,candidate.resolvingSymlinksInPath()==expected.resolvingSymlinksInPath(),try String(contentsOf:candidate.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Invalid owned incoming-source crash root")}
            root=candidate;keep=true
        } else if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_INCOMING_SOURCE_ROOT"] {
            let base=URL(fileURLWithPath:path,isDirectory:true)
            guard base.path==path,base.resolvingSymlinksInPath().path==path,fm.fileExists(atPath:base.deletingLastPathComponent().path) else {throw OSwindError.invalid("Invalid owned incoming-source output")}
            let marker=base.appendingPathComponent("owned-fixture")
            if !fm.fileExists(atPath:path) {try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored incoming source projection v1".utf8).write(to:marker,options:.withoutOverwriting)}
            guard try Data(contentsOf:marker)==Data("OSwind authored incoming source projection v1".utf8) else {throw OSwindError.invalid("Invalid owned source marker")}
            root=base.appendingPathComponent(name.replacingOccurrences(of:"[^A-Za-z0-9_.-]",with:"_",options:.regularExpression));guard !fm.fileExists(atPath:root.path) else {throw OSwindError.invalid("Owned source output must be fresh")};keep=true
        } else {root=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-"+UUID().uuidString)}
        try Paths.ensure(root)
    }
    override func tearDownWithError()throws {if !keep {try FileManager.default.removeItem(at:root)}}
    func endpoint(_ name:String,_ replica:String)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:root.appendingPathComponent(name))
        let cache=try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        try drain(store,cache);return(store,cache)
    }
    func paths(_ memory:Memory)->[SyncMediaRole:String] {
        var result=[SyncMediaRole:String]();result[.image]=memory.imagePath;result[.audio]=memory.audioPath;result[.video]=memory.videoPath;return result
    }
    func drain(_ store:MemoryStore,_ cache:SyncVersionStore,limit:Int=128)throws {
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:cache.catalog),cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{memory in
            try self.paths(memory).map {role,path in let bytes=try Data(contentsOf:store.root.appendingPathComponent(path)),ref=try SyncContentReference(data:bytes);return SyncMediaManifest(role:role,sha256:ref.sha256,bytes:ref.bytes,chunks:[ref])}.sorted {$0.role.rawValue<$1.role.rawValue}
        })
        for _ in 0..<2000 {if try processor.step(limit:limit) == .idle {return}}
        throw OSwindError.invalid("Owned source queue did not drain")
    }
    func packet(_ revision:SyncRevision,_ cache:SyncVersionStore)throws->SyncPortableRecord {
        let ref=try XCTUnwrap(revision.content),row=try cache.database.statement("SELECT body FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)};cache.database.bind(row,1,revision.key.digest);cache.database.bind(row,2,ref.sha256)
        guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {throw cache.database.error()};let record=try SyncPortableRecord.decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
        XCTAssertEqual(try record.reference.content,ref);return record
    }
    @discardableResult func receive(_ operation:SyncRevision,_ record:SyncPortableRecord,_ store:MemoryStore,_ cache:SyncVersionStore,media:[SyncMediaRole:String]=[:],fetch:@escaping (SyncVersionReference)throws->SyncPortableRecord)throws->String {
        let lease=try store.mediaWriteLease();defer {lease.release()};var result=""
        let writer=SyncIncomingConversationWriter(library:store,cache:cache,admit:{_ in},pathsFor:{_,_ in media},admitMedia:{_,_,_ in})
        let received=try cache.journal.receive(operation,contentAvailable:{_ in true}) {_ in result=try writer.apply(record,admission:lease,fetchExactSource:fetch)}
        XCTAssertEqual(received.applied,1,"Owned ordered fixture must actually apply its operation")
        return result
    }
    func receiveDeletion(_ operation:SyncRevision,_ store:MemoryStore,_ cache:SyncVersionStore)throws {
        let lease=try store.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:store,cache:cache,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        let received=try cache.journal.receive(operation,contentAvailable:{_ in true}) {change in XCTAssertEqual(change.revision,operation);try writer.applyDeletion(change,admission:lease)}
        XCTAssertEqual(received.applied,1)
    }
    func count(_ store:MemoryStore,_ table:String)throws->Int {try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM "+table)}}
    func testIncomingSourceProjectsExactScreenMediaMetadataAndWireBindingWithoutEcho()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let bytes=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII="));try bytes.write(to:a.root.appendingPathComponent("images/source.png"));try bytes.write(to:b.root.appendingPathComponent("images/incoming.png"))
        var memory=Memory(id:"original",timestamp:now,kind:.screen,app:"Owned Safari",bundleID:"org.owned.Safari",title:"Owned window",url:"https://owned.example.test",text:"Owned OCR text",imagePath:"images/source.png",regions:[.init(text:"Owned OCR text",x:0.1,y:0.1,width:0.6,height:0.2)],favorite:true,tags:["owned"])
        memory.embedding=[1,2];memory.embeddingModel="owned-local-only";try a.insert(memory);try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),before=try bc.journal.outbox()
        let id=try receive(operation,record,b,bc,media:[.image:"images/incoming.png"],fetch:{_ in throw OSwindError.invalid("No source dependencies")})
        guard case .source(let body)=record.body else {return XCTFail("No source body")}
        let expected=try body.projectedMemory(id:id,paths:[.image:"images/incoming.png"]) {_ in throw OSwindError.invalid("No source dependencies")}
        XCTAssertEqual(try b.get(id),expected);XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}),record);XCTAssertEqual(try bc.journal.outbox(),before)
        XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertEqual(try count(b,"memories"),1);XCTAssertEqual(try Data(contentsOf:b.root.appendingPathComponent("images/incoming.png")),bytes)
    }
    func testNewIncomingHeadPreservesCurrentAndHistoricalRecapChainsAndCitedOriginals()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"original",timestamp:now,kind:.note,app:"Owned",title:"Orion",text:"Alice owns Orion.");try a.insert(memory);try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().first),old=try packet(first,ac),id=try receive(first,old,b,bc,fetch:{_ in old})
        let source=try XCTUnwrap(b.get(id)),answer=Answer(text:"Owned first recap",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),one=try b.saveRecap(answer,title:"Recap one"),two=try b.saveRecap(.init(text:"Owned second recap",sources:[.init(memory:one,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),title:"Recap two")
        let chat=try b.createChat(title:"Keep exact source answers")
        _=try b.appendChatTurn(sessionID:chat.id,question:"Original owner?",answer:.init(text:"Alice [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]))
        _=try b.appendChatTurn(sessionID:chat.id,question:"Original second recap?",answer:.init(text:"Second recap [1]",sources:[.init(memory:two,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(b,bc)
        let oneID=try bc.catalog.localIdentity(.source,primary:[.text(Data(one.id.utf8))]),twoID=try bc.catalog.localIdentity(.source,primary:[.text(Data(two.id.utf8))]),oneWire=try bc.resolve(oneID,content:nil,admit:{_ in}),twoWire=try bc.resolve(twoID,content:nil,admit:{_ in})
        let original=try b.withRoutineDatabase {db in try HistoricalEvidenceStore(database:db).adopt(old.reference,cache:bc,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})}
        let outbox=try bc.journal.outbox(),versions=try count(b,"personal_sync_versions")
        memory.text="Bob now owns Orion.";try a.insert(memory);try drain(a,ac);let second=try XCTUnwrap(ac.journal.outbox().last),new=try packet(second,ac)
        XCTAssertEqual(try receive(second,new,b,bc,fetch:{ref in guard try ref==old.reference else {throw OSwindError.invalid("Unexpected dependency")};return old}),id)
        XCTAssertEqual(try b.get(id)?.text,memory.text);XCTAssertEqual(try b.get(one.id)?.text,one.text);XCTAssertEqual(try b.get(two.id)?.text,two.text)
        let turns=try b.chatTurns(chat.id);XCTAssertEqual(turns.count,2);XCTAssertEqual(turns.first?.answer.sources.first?.memory.text,source.text);XCTAssertEqual(turns.last?.answer.sources.first?.memory.text,two.text);XCTAssertNotNil(turns.first?.answer.sources.first?.memory.originalEvidence)
        XCTAssertEqual(try b.historicalMemory(original.handle).text,source.text)
        XCTAssertEqual(try b.recapEvidence(one.id).first?.memory.text,source.text);XCTAssertEqual(try b.recapEvidence(two.id).first?.memory.text,one.text)
        XCTAssertEqual(try bc.resolve(oneID,content:nil,admit:{_ in}),oneWire);XCTAssertEqual(try bc.resolve(twoID,content:nil,admit:{_ in}),twoWire);XCTAssertEqual(try bc.resolve(new.identity,content:nil,admit:{_ in}),new)
        XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertEqual(try count(b,"memories"),3);XCTAssertEqual(try count(b,"historical_evidence"),3);XCTAssertEqual(try count(b,"personal_sync_versions"),versions+1)
        if keep {try JSONSerialization.data(withJSONObject:["canonicalSource":id,"recapOne":one.id,"recapTwo":two.id,"conversation":chat.id,"originalHandle":original.handle,"oldWireSHA":try old.reference.content.sha256,"newWireSHA":try new.reference.content.sha256],options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("observed.json"))}
    }
    func testIncomingRecapAndDerivedCitationReplacementPreserveEvidenceAcrossSequence()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"original",timestamp:now,kind:.note,app:"Owned",text:"Alice owns Orion."));try drain(a,ac)
        let recap=try a.saveRecap(.init(text:"First recap text",sources:[.init(memory:XCTUnwrap(a.get("original")),score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),title:"Incoming recap");try drain(a,ac)
        var local="",old:SyncPortableRecord?,citation:SyncPortableRecord?
        for operation in try ac.journal.outbox() {
            let record=try packet(operation,ac)
            let id=try receive(operation,record,b,bc,fetch:{reference in guard let packet=try ac.record(reference,admit:{_ in}) else {throw OSwindError.invalid("Missing authored dependency")};return packet})
            if case .source(let body)=record.body,body.text==recap.text {local=id;old=record}
            if case .recapCitation=record.body {citation=record}
        }
        XCTAssertFalse(local.isEmpty);let prior=try XCTUnwrap(old),link=try XCTUnwrap(citation),chat=try b.createChat(title:"Original recap answer")
        _=try b.appendChatTurn(sessionID:chat.id,question:"Original recap?",answer:.init(text:"First recap [1]",sources:[.init(memory:XCTUnwrap(b.get(local)),score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(b,bc)
        let before=try bc.journal.outbox(),initialThrough=try ac.journal.outbox().last!.dot.counter,identity=try bc.catalog.localIdentity(.recapCitation,primary:[.text(Data(local.utf8)),.integer(0)])
        XCTAssertEqual(identity,link.identity)
        var changed=recap;changed.text="Newer recap text";try a.insert(changed);try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first {r in r.key == (try? prior.identity.key) && r.content != (try? prior.reference.content)}),packet=try packet(operation,ac)
        // Outgoing privacy deletes precede the new source put. Retire the old
        // citation globally while retaining the owner's required derived row.
        for prerequisite in try ac.journal.outbox() where prerequisite.dot.counter>initialThrough && prerequisite.dot.counter<operation.dot.counter {
            XCTAssertEqual(prerequisite.mutation,.delete);try receiveDeletion(prerequisite,b,bc)
        }
        XCTAssertTrue(try bc.catalog.object(identity)?.deleted==true)
        XCTAssertThrowsError(try bc.resolve(identity,content:nil,admit:{_ in}))
        XCTAssertEqual(try count(b,"recap_sources"),1)
        XCTAssertEqual(try receive(operation,packet,b,bc,fetch:{reference in guard let packet=try ac.record(reference,admit:{_ in}) else {throw OSwindError.invalid("Missing authored parent")};return packet}),local)
        var replacement:SyncPortableRecord?
        for following in try ac.journal.outbox() where following.dot.counter>operation.dot.counter {
            let record=try self.packet(following,ac)
            _=try receive(following,record,b,bc,fetch:{reference in guard let packet=try ac.record(reference,admit:{_ in}) else {throw OSwindError.invalid("Missing authored parent")};return packet})
            if case .recapCitation=record.body {replacement=record}
        }
        let newLink=try XCTUnwrap(replacement);XCTAssertNotEqual(newLink.identity,identity)
        XCTAssertEqual(try b.get(local)?.text,changed.text);XCTAssertEqual(try b.recapEvidence(local).first?.memory.text,"Alice owns Orion.")
        XCTAssertEqual(try b.chatTurns(chat.id).first?.answer.sources.first?.memory.text,recap.text)
        XCTAssertEqual(try bc.catalog.localIdentity(.recapCitation,primary:[.text(Data(local.utf8)),.integer(0)]),newLink.identity)
        XCTAssertEqual(try bc.resolve(newLink.identity,content:nil,admit:{_ in}),newLink);XCTAssertEqual(try bc.journal.outbox(),before);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testIncomingAudioPreservesSessionAndAttributionWithoutLocalModelAuthority()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var bytes=Data("RIFF".utf8)
        func little<T:FixedWidthInteger>(_ value:T) {var v=value.littleEndian;withUnsafeBytes(of:&v){bytes.append(contentsOf:$0)}}
        little(UInt32(3236));bytes.append(Data("WAVEfmt ".utf8));little(UInt32(16));little(UInt16(1));little(UInt16(1));little(UInt32(16000));little(UInt32(32000));little(UInt16(2));little(UInt16(16));bytes.append(Data("data".utf8));little(UInt32(3200));bytes.append(Data(repeating:0,count:3200))
        try bytes.write(to:a.root.appendingPathComponent("audio/source.wav"));try bytes.write(to:b.root.appendingPathComponent("audio/received.wav"))
        var memory=Memory(id:"speech",timestamp:now,kind:.audio,app:"Owned microphone",text:"Owned speech",audioPath:"audio/source.wav")
        memory.audioSessionID="/Users/OWNED-FAKE-DEVICE/private-session";memory.transcript = .init(text:memory.text,duration:0.1,segments:[.init(start:0,end:0.1,text:memory.text)],model:"/Users/OWNED-FAKE-DEVICE/model")
        try a.insert(memory);try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac)
        let id=try receive(operation,record,b,bc,media:[.audio:"audio/received.wav"],fetch:{_ in throw OSwindError.invalid("No audio dependency")})
        guard case .source(let body)=record.body else {return XCTFail("No audio source")}
        XCTAssertFalse(String(decoding:try record.encoded(),as:UTF8.self).contains("OWNED-FAKE-DEVICE"));XCTAssertEqual(try b.get(id)?.audioSessionID,body.audioSession?.localProjection);XCTAssertEqual(try b.get(id)?.transcript?.model,"peer-unspecified")
        XCTAssertEqual(try bc.sessionBinding(localID:id,admit:{_ in}),body.audioSession);XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}),record);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testIncomingSampledSpanMovesExistingPinToOldVersionAndOrdinaryEditStillInvalidates()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"sampled",timestamp:now,endTimestamp:now.addingTimeInterval(2),kind:.screen,app:"Owned text",text:"Repeated text",display:AccessibilityCaptureRecord.display)
        memory.textObservation = .init(sessionID:"00000000-0000-0000-0000-000000006111",samples:2,largestGapSeconds:2);try a.insert(memory);try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().first),record=try packet(first,ac),id=try receive(first,record,b,bc,fetch:{_ in record})
        let old=try XCTUnwrap(b.get(id));try b.withRoutineDatabase {try $0.pinTextObservation(old)};try drain(b,bc)
        let pinID=try bc.catalog.localIdentity(.evidencePin,primary:[.text(Data(id.utf8))]),pin=try bc.resolve(pinID,content:nil,admit:{_ in}),before=try bc.journal.outbox()
        memory.endTimestamp=now.addingTimeInterval(5);memory.textObservation = .init(sessionID:memory.textObservation!.sessionID,samples:3,largestGapSeconds:3);try a.insert(memory);try drain(a,ac)
        let next=try XCTUnwrap(ac.journal.outbox().last),new=try packet(next,ac);XCTAssertEqual(try receive(next,new,b,bc,fetch:{_ in record}),id)
        XCTAssertEqual(try b.get(id)?.endTimestamp,memory.endTimestamp);XCTAssertEqual(try bc.resolve(pinID,content:nil,admit:{_ in}),pin);XCTAssertEqual(try bc.journal.outbox(),before)
        let original=try b.withRoutineDatabase {db -> String in let row=try db.statement("SELECT handle FROM historical_evidence_pins WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)}
        XCTAssertEqual(try b.historicalMemory(original).endTimestamp,old.endTimestamp)
        var local=try XCTUnwrap(b.get(id));local.text="Explicit local correction";try b.insert(local)
        XCTAssertThrowsError(try b.historicalMemory(original));XCTAssertEqual(try count(b,"historical_evidence_pins"),0)
    }

    func testDeniedPolicyForeignAndReleasedReservationsAndIdentifierCollisionRollbackReceipt()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Incoming exact text"));try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac)
        try b.insert(Memory(id:"collision",timestamp:now,kind:.note,app:"Owned",text:"Independent local source"));try drain(b,bc)
        let outbox=try bc.journal.outbox(),versions=try count(b,"personal_sync_versions")
        let own=try b.mediaWriteLease(),foreign=try a.mediaWriteLease(),released=try b.mediaWriteLease();released.release();defer {own.release();foreign.release()}
        let regular=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        let denied=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in throw OSwindError.unavailable("Owned policy denial")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        let collision=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in},newID:{_ in "collision"})
        for (writer,lease) in [(regular,foreign),(regular,released),(denied,own),(collision,own)] {
            XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
                _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No dependency")})
            })
            XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
            XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertEqual(try bc.journal.outbox(),outbox)
            XCTAssertEqual(try count(b,"personal_sync_versions"),versions);XCTAssertEqual(try count(b,"memories"),1)
            XCTAssertEqual(try b.get("collision")?.text,"Independent local source")
        }
        XCTAssertFalse(try receive(operation,record,b,bc,fetch:{_ in record}).isEmpty)
        XCTAssertEqual(try count(b,"memories"),2)
    }

    func testLateHeadAndNativeMutationRefuseAndRollbackEntireIncomingReceipt()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Incoming exact text"));try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),local="peer-"+(try record.identity.key.digest)
        let lease=try b.mediaWriteLease();defer {lease.release()}
        for mode in ["head","native"] {
            var mutated=false
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in
                guard !mutated,var native=try b.get(local) else {return};mutated=true
                if mode=="head" {_=try bc.journal.delete(key:record.identity.key)}
                else {native.text="Late native mutation";try b.insert(native)}
            },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
                _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No dependency")})
            })
            XCTAssertTrue(mutated);XCTAssertNil(try b.get(local));XCTAssertNil(try bc.catalog.object(record.identity))
            let state=try bc.journal.state(for:record.identity.key);XCTAssertTrue(state.heads.isEmpty);XCTAssertFalse(state.isDeleted)
            XCTAssertTrue(try bc.journal.outbox().isEmpty)
            for table in ["personal_sync_versions","personal_sync_changes","historical_evidence"] {XCTAssertEqual(try count(b,table),0)}
        }
        XCTAssertEqual(try receive(operation,record,b,bc,fetch:{_ in record}),local)
    }
    func testLateMediaByteMutationRefusesDatabaseProjectionWithoutPretendingToUndoCallerWrites()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let bytes=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII=")),source=a.root.appendingPathComponent("images/source.png"),target=b.root.appendingPathComponent("images/staged.png")
        try bytes.write(to:source);try bytes.write(to:target)
        try a.insert(Memory(id:"source",timestamp:now,kind:.screen,app:"Owned",text:"Owned image",imagePath:"images/source.png"));try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),local="peer-"+(try record.identity.key.digest)
        let lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let changed=Data("Externally changed owned staged bytes".utf8)
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [.image:"images/staged.png"]},admitMedia:{_,_,_ in
            if !mutated,try b.get(local) != nil {mutated=true;try changed.write(to:target)}
        })
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No dependency")})
        })
        XCTAssertTrue(mutated);XCTAssertEqual(try Data(contentsOf:target),changed)
        XCTAssertNil(try b.get(local));XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
        XCTAssertTrue(try bc.journal.outbox().isEmpty);XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
        try bytes.write(to:target)
        XCTAssertEqual(try receive(operation,record,b,bc,media:[.image:"images/staged.png"],fetch:{_ in record}),local)
    }

    func testLateAncestorJournalDeletionCannotCommitNewRecapGraph()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"ancestor",timestamp:now,kind:.note,app:"Owned",text:"Exact ancestor"))
        let one=try a.saveRecap(.init(text:"Intermediate recap",sources:[.init(memory:XCTUnwrap(a.get("ancestor")),score:1,match:"owned")],provider:"owned",duration:0),title:"Intermediate")
        let two=try a.saveRecap(.init(text:"Newest recap",sources:[.init(memory:one,score:1,match:"owned")],provider:"owned",duration:0),title:"Newest");try drain(a,ac)
        var ancestor:SyncObjectIdentity?,pending:(SyncRevision,SyncPortableRecord)?
        for operation in try ac.journal.outbox() {
            let packet=try self.packet(operation,ac)
            if case .source(let body)=packet.body,body.text==two.text {pending=(operation,packet);break}
            _=try receive(operation,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if case .source(let body)=packet.body,body.text=="Exact ancestor" {ancestor=packet.identity}
        }
        let (operation,record)=try XCTUnwrap(pending),ancestorIdentity=try XCTUnwrap(ancestor),local="peer-"+(try record.identity.key.digest)
        let lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let outbox=try bc.journal.outbox(),versions=try count(b,"personal_sync_versions"),originals=try count(b,"historical_evidence")
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in
            if !mutated,try b.get(local) != nil {mutated=true;_=try bc.journal.delete(key:ancestorIdentity.key)}
        })
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        })
        XCTAssertTrue(mutated);XCTAssertNil(try b.get(local));XCTAssertNil(try bc.catalog.object(record.identity))
        XCTAssertFalse(try bc.journal.state(for:ancestorIdentity.key).isDeleted);XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
        XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try count(b,"personal_sync_versions"),versions);XCTAssertEqual(try count(b,"historical_evidence"),originals);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }

    func testByteDistinctUnicodeRecapOwnersPreserveSeparateOriginalsAndBindings()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Old exact source");try a.insert(memory);try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().first),old=try packet(first,ac),local=try receive(first,old,b,bc,fetch:{_ in old}),source=try XCTUnwrap(b.get(local))
        let ids=["caf\u{e9}","cafe\u{301}"],texts=["First byte-distinct recap","Second byte-distinct recap"],chat=try b.createChat(title:"Separate byte-exact owners")
        XCTAssertEqual(ids[0],ids[1]);XCTAssertNotEqual(Data(ids[0].utf8),Data(ids[1].utf8))
        for index in ids.indices {
            var recap=Memory(id:ids[index],timestamp:now,kind:.summary,app:"OSwind",title:"Owned recap",text:texts[index])
            recap.recap = .init(provider:"owned",sources:[.init(id:local,revision:source.evidenceHash,match:"owned",score:1,passage:nil)])
            try b.insert(recap)
            _=try b.appendChatTurn(sessionID:chat.id,question:"Which original?",answer:.init(text:texts[index],sources:[.init(memory:recap,score:1,match:"owned")],provider:"owned",duration:0))
        }
        try drain(b,bc)
        let identities=try ids.map {try bc.catalog.localIdentity(.source,primary:[.text(Data($0.utf8))])},packets=try identities.map {try bc.resolve($0,content:nil,admit:{_ in})},outbox=try bc.journal.outbox()
        XCTAssertNotEqual(identities[0],identities[1])
        memory.text="New current source";try a.insert(memory);try drain(a,ac)
        let next=try XCTUnwrap(ac.journal.outbox().last),new=try packet(next,ac);_=try receive(next,new,b,bc,fetch:{_ in old})
        for index in ids.indices {
            XCTAssertEqual(try b.get(ids[index])?.text,texts[index]);XCTAssertEqual(try b.recapEvidence(ids[index]).first?.memory.text,"Old exact source")
            XCTAssertEqual(try bc.resolve(identities[index],content:nil,admit:{_ in}),packets[index])
        }
        XCTAssertEqual(Set(try b.chatTurns(chat.id).compactMap {$0.answer.sources.first?.memory.text}),Set(texts))
        XCTAssertEqual(try count(b,"historical_evidence"),3);XCTAssertEqual(try count(b,"memories"),3);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertEqual(try bc.journal.outbox(),outbox)
    }

    func testLateConversationHeadReplacementCannotCommitStaleProjection()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.createChat(title:"Owned incoming conversation");try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let changed=try SyncContentReference(data:Data("Owned late different head".utf8))
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{packet in
            if !mutated,packet.identity==record.identity,try bc.catalog.object(record.identity) != nil,try bc.record(record.reference,admit:{_ in}) != nil {mutated=true;_=try bc.journal.put(key:record.identity.key,content:changed)}
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{_ in record})})
        XCTAssertTrue(mutated);XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        for table in ["chat_sessions","personal_sync_versions","personal_sync_changes"] {XCTAssertEqual(try count(b,table),0)}
    }
    func testLateAncestorDeletionDuringRecapCitationAdmissionRollsBackReceiptAndBinding()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"ancestor",timestamp:now,kind:.note,app:"Owned",text:"Exact cited ancestor"))
        let one=try a.saveRecap(.init(text:"Intermediate cited recap",sources:[.init(memory:XCTUnwrap(a.get("ancestor")),score:1,match:"owned")],provider:"owned",duration:0),title:"Intermediate")
        let two=try a.saveRecap(.init(text:"Newest cited recap",sources:[.init(memory:one,score:1,match:"owned")],provider:"owned",duration:0),title:"Newest");try drain(a,ac)
        let owner=try ac.catalog.localIdentity(.source,primary:[.text(Data(two.id.utf8))]);var ancestor:SyncObjectIdentity?,pending:(SyncRevision,SyncPortableRecord)?
        for operation in try ac.journal.outbox() {
            let packet=try self.packet(operation,ac)
            if case .recapCitation(let body)=packet.body,body.owner==owner {pending=(operation,packet);break}
            _=try receive(operation,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if case .source(let body)=packet.body,body.text=="Exact cited ancestor" {ancestor=packet.identity}
        }
        let (operation,record)=try XCTUnwrap(pending),ancestorIdentity=try XCTUnwrap(ancestor),lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let outbox=try bc.journal.outbox(),versions=try count(b,"personal_sync_versions"),originals=try count(b,"historical_evidence"),links=try count(b,"recap_sources")
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{packet in
            if !mutated,packet.identity==record.identity,try bc.catalog.object(record.identity) != nil {mutated=true;_=try bc.journal.delete(key:ancestorIdentity.key)}
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})})
        XCTAssertTrue(mutated);XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertFalse(try bc.journal.state(for:ancestorIdentity.key).isDeleted);XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
        XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try count(b,"personal_sync_versions"),versions);XCTAssertEqual(try count(b,"historical_evidence"),originals);XCTAssertEqual(try count(b,"recap_sources"),links);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }

    func testLateConversationAncestorDeletionDuringChatCitationAdmissionRefuses()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let source=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Owned cited source");try a.insert(source)
        let chat=try a.createChat(title:"Owned conversation ancestor");_=try a.appendChatTurn(sessionID:chat.id,question:"Source?",answer:.init(text:"Owned answer [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0));try drain(a,ac)
        var ancestor:SyncObjectIdentity?,pending:(SyncRevision,SyncPortableRecord)?
        for operation in try ac.journal.outbox() {
            let packet=try self.packet(operation,ac)
            if case .conversationCitation=packet.body {pending=(operation,packet);break}
            _=try receive(operation,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if case .conversation=packet.body {ancestor=packet.identity}
        }
        let (operation,record)=try XCTUnwrap(pending),ancestorIdentity=try XCTUnwrap(ancestor),lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let outbox=try bc.journal.outbox(),versions=try count(b,"personal_sync_versions"),turns=try count(b,"chat_turns")
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{packet in
            if !mutated,packet.identity==record.identity,try bc.catalog.object(record.identity) != nil {mutated=true;_=try bc.journal.delete(key:ancestorIdentity.key)}
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})})
        XCTAssertTrue(mutated);XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertFalse(try bc.journal.state(for:ancestorIdentity.key).isDeleted);XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
        XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try count(b,"personal_sync_versions"),versions);XCTAssertEqual(try count(b,"chat_turns"),turns);XCTAssertEqual(try count(b,"chat_sources"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }

}
