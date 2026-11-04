import XCTest
import CSQLite
@testable import OSwindCore

private struct RecordingSecondaryOriginal {
    let record:SyncPortableRecord,handle:String,caption:String
}
private final class RecordingRevalidationCancellationGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"recording revalidation canonical scan")
    private let condition=NSCondition()
    private var observed=false,released=false
    func pause() {
        condition.lock();defer {condition.unlock()}
        if observed {return};observed=true;entered.fulfill()
        let deadline=Date().addingTimeInterval(5)
        while !released && condition.wait(until:deadline) {}
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}
private struct RecordingOriginalPeerFixture {
    let a:MemoryStore,b:MemoryStore,ac:SyncVersionStore,bc:SyncVersionStore
    let original:SyncPortableRecord,metadata:SyncPortableRecord,latestAudio:SyncRevision
    let clip:String,caption:String,handle:String,mediaPath:String,bytes:Data
    let secondary:RecordingSecondaryOriginal?
}
extension SyncIncomingSourceTests {

    func testRecordingOriginalRecoveryOversizedMetadataRefusesNativeWriteWithoutBlockingErasure()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let target="a"+String(repeating:"\u{0301}",count:18000),scope=try RecordingScope(sourceID:target,revision:"authored-missing-evidence")
        XCTAssertLessThan(target.count,200);XCTAssertGreaterThan(target.utf8.count,32768)
        var label=Memory(id:"oversized-grapheme-revalidation-caption",kind:.recordingMetadata,app:"OSwind",title:"Authored unavailable target",text:"User-authored label");label.recordingDetails = .init(scope:scope)
        let marker=try recordingRevalidationValue(f.b),outbox=try f.bc.journal.outbox(),caption=try f.b.get(f.caption),audio=try f.b.get(f.clip)
        XCTAssertThrowsError(try f.b.insert(label)) {error in
            guard case OSwindError.invalid(let message)=error else {return XCTFail("Unexpected oversized metadata refusal: \(error)")}
            XCTAssertEqual(message,"Recording metadata exceeds 32 KiB")
        }
        XCTAssertNil(try f.b.get(label.id));XCTAssertEqual(try f.bc.journal.outbox(),outbox);XCTAssertEqual(try recordingRevalidationValue(f.b),marker)
        XCTAssertEqual(try f.b.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM personal_sync_work")},0)
        try eraseRecordingOriginalOnly(f);try drain(f.b,f.bc,limit:1)
        XCTAssertEqual(try f.b.get(f.caption),caption);XCTAssertEqual(try f.b.get(f.clip),audio)
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing reconciled recording after refused oversized write")};XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
    }


    func testRecordingOriginalRecoveryNoEditBoundedCanonicalScanAtAuthoredScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_RECORDING_RECONCILIATION_BENCH_DIR"] else {throw XCTSkip("Explicit authored recording reconciliation scale measurement")}
        let output=URL(fileURLWithPath:path,isDirectory:true);try Paths.ensure(output)
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let count=2000,limit=64,start=ProcessInfo.processInfo.systemUptime
        try f.b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
            for index in 0..<count {
                var label=Memory(id:String(format:"dense-revalidation-%05d",index),kind:.recordingMetadata,app:"OSwind",title:"Authored unavailable target",text:"User-authored label")
                label.recordingDetails = .init(scope:try .init(sourceID:"a-missing-target",revision:"authored-missing-evidence"));try f.b.insert(label)
            }
        }}
        try drain(f.b,f.bc);let setup=ProcessInfo.processInfo.systemUptime-start
        let caption=try XCTUnwrap(f.b.get(f.caption)),audio=try XCTUnwrap(f.b.get(f.clip)),erasureStart=ProcessInfo.processInfo.systemUptime
        try eraseRecordingOriginalOnly(f);let erasure=ProcessInfo.processInfo.systemUptime-erasureStart
        let processor=try recordingRevalidationProcessor(f.b,f.bc);var scanned=0,queued=0,finished=false,observations=[[String:Any]]();let run=ProcessInfo.processInfo.systemUptime
        for _ in 0..<2000 {
            let before=ProcessInfo.processInfo.systemUptime,step=try processor.step(limit:limit),elapsed=ProcessInfo.processInfo.systemUptime-before
            if case .revalidatingRecordings(let rows,let work)=step {
                XCTAssertLessThanOrEqual(rows,limit);scanned+=rows;queued+=work
                observations.append(["phase":"revalidation","scanned":rows,"queued":work,"seconds":elapsed,"markerBytes":try recordingRevalidationValue(f.b).utf8.count])
            }else {observations.append(["phase":step == .idle ? "idle":"ordinary-work","seconds":elapsed])}
            if step == .idle {finished=true;break}
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-run
        XCTAssertTrue(finished);XCTAssertEqual(scanned,count+1);XCTAssertEqual(queued,1)
        XCTAssertEqual(try f.b.get(f.caption),caption);XCTAssertEqual(try f.b.get(f.clip),audio)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}))
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing reconciled dense recording")};XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
        let report:[String:Any]=["scope":"Authored single-host two-local-endpoint bounded canonical reconciliation, not power/provider/competitor measurement","unaffectedLabels":count,"affectedLabels":1,"batchLimit":limit,"scanned":scanned,"queued":queued,"setupSeconds":setup,"erasureSeconds":erasure,"reconciliationSeconds":elapsed,"observations":observations]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("report.json"),options:.withoutOverwriting)
    }

    private func ownedRecordingWave()->Data {
        var result=Data()
        func append<T:FixedWidthInteger>(_ value:T) {var value=value.littleEndian;withUnsafeBytes(of:&value) {result.append(contentsOf:$0)}}
        result.append(Data("RIFF".utf8));append(UInt32(36+3200));result.append(Data("WAVEfmt ".utf8));append(UInt32(16));append(UInt16(1));append(UInt16(1));append(UInt32(16000));append(UInt32(32000));append(UInt16(2));append(UInt16(16));result.append(Data("data".utf8));append(UInt32(3200))
        for sample in 0..<1600 {append(Int16(sample%32<16 ? 2000:-2000))}
        return result
    }
    private func receiveRecording(_ operation:SyncRevision,_ record:SyncPortableRecord,_ store:MemoryStore,_ cache:SyncVersionStore,media:[SyncMediaRole:String],fetch:@escaping (SyncVersionReference)throws->SyncPortableRecord)throws->String {
        let lease=try store.mediaWriteLease();defer {lease.release()};var result=""
        let writer=SyncIncomingConversationWriter(library:store,cache:cache,admit:{_ in},pathsFor:{_,manifests in
            media.filter {role,_ in manifests.contains {$0.role==role}}
        },admitMedia:{_,manifests,paths in
            for manifest in manifests {
                guard let path=paths[manifest.role] else {throw OSwindError.invalid("Owned fixture media role is missing")}
                let content=try SyncContentReference(data:Data(contentsOf:store.root.appendingPathComponent(path)))
                guard content.sha256==manifest.sha256,content.bytes==manifest.bytes,manifest.chunks==[content] else {throw OSwindError.invalid("Owned fixture media bytes differ")}
            }
        })
        let received=try cache.journal.receive(operation,contentAvailable:{_ in true}) {_ in result=try writer.apply(record,admission:lease,fetchExactSource:fetch)}
        XCTAssertEqual(received.applied,1);return result
    }
    /// Two actual local typed/journal endpoints and authored PCM bytes.
    /// No device enrollment, background service, provider or microphone.
    private func recordingOriginalPeerFixture(secondOriginal:Bool=false)throws->RecordingOriginalPeerFixture {
        var stores=[MemoryStore](),ready=false;defer {if !ready {for store in stores {try? store.close()}}}
        let (a,ac)=try endpoint("producer",producerID);stores.append(a)
        let (b,bc)=try endpoint("receiver",receiverID);stores.append(b);try bc.journal.allowPeer(producerID)
        let bytes=ownedRecordingWave(),producerPath="audio/owned-original.wav",receiverPath="audio/received-original.wav"
        try Paths.ensure(a.root.appendingPathComponent("audio"));try Paths.ensure(b.root.appendingPathComponent("audio"))
        try bytes.write(to:a.root.appendingPathComponent(producerPath),options:.withoutOverwriting);try bytes.write(to:b.root.appendingPathComponent(receiverPath),options:.withoutOverwriting)
        var audio=Memory(id:"owned-recoverable-audio",timestamp:now,kind:.audio,app:"Original authored app",title:"Original authored capture",text:"Original authored speech");audio.audioPath=producerPath;try a.insert(audio);try drain(a,ac)
        let audioOp=try XCTUnwrap(ac.journal.outbox().first),original=try packet(audioOp,ac)
        let clip=try receiveRecording(audioOp,original,b,bc,media:[.audio:receiverPath],fetch:{_ in original})
        let source=try XCTUnwrap(a.recordedMeetingPage().sources.first),name=try a.saveRecordedMeetingName("Authored archived conversation",for:source);try drain(a,ac)
        let identity=try ac.catalog.localIdentity(.source,primary:[.text(Data(name.id.utf8))]),key=try identity.key
        let metadataOp=try XCTUnwrap(ac.journal.outbox().first {$0.key==key}),metadata=try packet(metadataOp,ac)
        let caption=try receiveRecording(metadataOp,metadata,b,bc,media:[.audio:receiverPath],fetch:{reference in XCTAssertEqual(reference,try original.reference);return original})
        let retained=try b.withRoutineDatabase {db in try b.historicalCatalog(db).adopt(original.reference,cache:bc,pathsFor:{_,_ in [.audio:receiverPath]},admit:{_ in},verifyMedia:{_,manifests,paths in
            XCTAssertEqual(paths[.audio],receiverPath);XCTAssertEqual(manifests.first?.sha256,try SyncContentReference(data:bytes).sha256)
        })}
        var secondary:RecordingSecondaryOriginal?
        if secondOriginal {
            audio.text="Intermediate authored speech";audio.app="Intermediate authored app";audio.timestamp=now.addingTimeInterval(1800);try a.insert(audio);try drain(a,ac)
            let operation=try XCTUnwrap(ac.journal.outbox().last {$0.key==audioOp.key}),packet=try self.packet(operation,ac)
            _=try receiveRecording(operation,packet,b,bc,media:[.audio:receiverPath],fetch:{_ in original})
            let historical=try b.withRoutineDatabase {db in try b.historicalCatalog(db).adopt(packet.reference,cache:bc,pathsFor:{_,_ in [.audio:receiverPath]},admit:{_ in},verifyMedia:b.verifyHistoricalMedia)}
            let current=try XCTUnwrap(b.get(clip));var label=Memory(id:"zz-secondary-recording-caption",kind:.recordingMetadata,app:"OSwind",title:"Authored intermediate recording name",text:"User-authored label")
            label.recordingDetails = .init(scope:try .init(sourceID:clip,revision:current.evidenceHash));try b.insert(label);try drain(b,bc)
            secondary = .init(record:packet,handle:historical.handle,caption:label.id)
        }
        audio.text="Current independent authored speech";audio.app="Current authored app";audio.timestamp=now.addingTimeInterval(3600);try a.insert(audio);try drain(a,ac)
        let latest=try XCTUnwrap(ac.journal.outbox().last {$0.key==audioOp.key && $0.content != audioOp.content}),current=try packet(latest,ac)
        _=try receiveRecording(latest,current,b,bc,media:[.audio:receiverPath],fetch:{_ in original})
        try b.withRoutineDatabase {db in
            let row=try db.statement("DELETE FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)};db.bind(row,1,try original.identity.key.digest);db.bind(row,2,try original.reference.content.sha256);try db.done(row);XCTAssertEqual(sqlite3_changes(db.handle),1)
        }
        XCTAssertNil(try bc.record(original.reference,admit:{_ in}));XCTAssertEqual(try b.get(clip)?.text,audio.text)
        ready=true;return .init(a:a,b:b,ac:ac,bc:bc,original:original,metadata:metadata,latestAudio:latest,clip:clip,caption:caption,handle:retained.handle,mediaPath:receiverPath,bytes:bytes,secondary:secondary)
    }
    func testRecordingOriginalRecoveryFromIncomingHistoryRepublishesExactAudioWithoutChangingItsHead()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        let head=try f.bc.journal.state(for:f.latestAudio.key).heads
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let record=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in})
        guard case .source(let body)=record.body else {return XCTFail("Missing recording metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try f.original.reference)
        XCTAssertEqual(try f.bc.record(f.original.reference,admit:{_ in}),f.original)
        XCTAssertEqual(try f.bc.journal.state(for:f.latestAudio.key).heads,head,"Recovery must not publish the old audio as a new live head")
        XCTAssertTrue(try f.bc.journal.outbox().allSatisfy {$0.key == (try? f.metadata.identity.key)})
        try f.ac.journal.allowPeer(receiverID)
        let operation=try XCTUnwrap(f.bc.journal.outbox().last)
        _=try receiveRecording(operation,record,f.a,f.ac,media:[.audio:"audio/owned-original.wav"],fetch:{reference in try XCTUnwrap(f.bc.record(reference,admit:{_ in}))})
        XCTAssertEqual(try f.ac.resolve(f.metadata.identity,content:nil,admit:{_ in}).body,record.body)
    }
    func testRecordingOriginalRecoveryRevalidatesActualRetainedAudioBytesBeforeRepublishing()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        let file=f.b.root.appendingPathComponent(f.mediaPath);try f.b.setFavorite(f.caption,value:true)
        try Data("Authored wrong bytes".utf8).write(to:file);XCTAssertThrowsError(try drain(f.b,f.bc))
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));XCTAssertTrue(try f.bc.journal.outbox().isEmpty)
        try FileManager.default.removeItem(at:file);XCTAssertThrowsError(try drain(f.b,f.bc))
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));XCTAssertTrue(try f.bc.journal.outbox().isEmpty)
        try f.bytes.write(to:file,options:.withoutOverwriting);try drain(f.b,f.bc)
        XCTAssertEqual(try f.bc.record(f.original.reference,admit:{_ in}),f.original)
    }
    func testRecordingOriginalRecoveryCannotUndoOriginalOnlyErasureWhileCurrentAudioSurvives()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let current=try XCTUnwrap(f.b.get(f.clip)),caption=try XCTUnwrap(f.b.get(f.caption)),scope=HistoryErasureScope(end:now.addingTimeInterval(1),kind:.audio)
        let preview=try f.b.previewErasure(scope);XCTAssertEqual(preview.matchedSources,0);XCTAssertEqual(preview.matchedHistoricalVersions,1)
        _=try f.b.eraseHistory(scope,expectedToken:preview.token)
        XCTAssertEqual(try f.b.get(f.clip),current);XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}))
        XCTAssertEqual(try Data(contentsOf:f.b.root.appendingPathComponent(f.mediaPath)),f.bytes,"The current recording still uses this asset")
        let resolution=try f.b.withRoutineDatabase {db in try f.bc.recordingSourceBinding(caption,historical:f.b.historicalCatalog(db),admit:{_ in},verifyOriginal:{_ in})}
        XCTAssertEqual(resolution,.unavailable,"A retained authored name must not select another version after its exact original is erased")
        XCTAssertEqual(try f.b.get(f.caption),caption)
        XCTAssertThrowsError(try f.bc.retain(f.original,requiredBy:f.metadata,admit:{_ in}))
        XCTAssertThrowsError(try f.b.withRoutineDatabase {db in try f.b.historicalCatalog(db).insert(handle:f.handle,source:f.clip,record:f.original,paths:[.audio:f.mediaPath],parents:[])})
        try f.b.setFavorite(f.caption,value:false);try drain(f.b,f.bc)
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing authored metadata after erasure")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertTrue(body.sourceReferences.isEmpty)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));XCTAssertEqual(try f.b.get(f.clip),current)
    }
    func testRecordingOriginalRecoveryOriginalOnlyErasureReconcilesHeadWithoutCaptionEdit()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        // Establish a real locally authored outgoing label before erasure.
        // No caption edit after erasure may be required to repair its dependency.
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let caption=try XCTUnwrap(f.b.get(f.caption)),current=try XCTUnwrap(f.b.get(f.clip))
        let audioHeads=try f.bc.journal.state(for:f.latestAudio.key).heads
        let oldLabel=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in})
        let scope=HistoryErasureScope(end:now.addingTimeInterval(1),kind:.audio),preview=try f.b.previewErasure(scope)
        XCTAssertEqual(preview.matchedSources,0);XCTAssertEqual(preview.matchedHistoricalVersions,1)
        _=try f.b.eraseHistory(scope,expectedToken:preview.token)
        XCTAssertEqual(try f.b.get(f.caption),caption);XCTAssertEqual(try f.b.get(f.clip),current)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}))
        let record:SyncPortableRecord
        do {try drain(f.b,f.bc);record=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in})}
        catch {return XCTFail("Original-only erasure must reconcile the live label head without a caption edit: \(error)")}
        guard case .source(let body)=record.body else {return XCTFail("Missing reconciled authored metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertTrue(body.sourceReferences.isEmpty)
        XCTAssertNotEqual(try record.reference,try oldLabel.reference)
        XCTAssertEqual(try f.b.get(f.caption),caption,"Derived wire reconciliation must not rewrite canonical user metadata")
        XCTAssertEqual(try f.b.get(f.clip),current);XCTAssertEqual(try f.bc.journal.state(for:f.latestAudio.key).heads,audioHeads)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}))
        XCTAssertEqual(try Data(contentsOf:f.b.root.appendingPathComponent(f.mediaPath)),f.bytes)
    }
    private func eraseRecordingOriginalOnly(_ f:RecordingOriginalPeerFixture)throws {
        let scope=HistoryErasureScope(end:now.addingTimeInterval(1),kind:.audio),preview=try f.b.previewErasure(scope)
        XCTAssertEqual(preview.matchedSources,0);XCTAssertEqual(preview.matchedHistoricalVersions,1)
        _=try f.b.eraseHistory(scope,expectedToken:preview.token)
    }
    private func recordingRevalidationProcessor(_ store:MemoryStore,_ cache:SyncVersionStore,admit:@escaping (SyncPortableRecord)throws->Void={_ in})throws->SyncOutgoingProcessor {
        .init(queue:try .install(catalog:cache.catalog),cache:cache,admitRow:{_,_ in},admitVersion:admit,media:{memory in
            try self.paths(memory).map {role,path in let bytes=try Data(contentsOf:store.root.appendingPathComponent(path)),ref=try SyncContentReference(data:bytes);return SyncMediaManifest(role:role,sha256:ref.sha256,bytes:ref.bytes,chunks:[ref])}.sorted {$0.role.rawValue<$1.role.rawValue}
        })
    }
    private func recordingRevalidationValue(_ store:MemoryStore)throws->String {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,SyncRecordingReconciliation.key)
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)
        }
    }
    func testRecordingOriginalRecoveryNoEditErasureUsesRealEncryptedSupersessionWithoutOldBody()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let old=try XCTUnwrap(f.bc.journal.outbox().last),caption=try XCTUnwrap(f.b.get(f.caption))
        try eraseRecordingOriginalOnly(f);try drain(f.b,f.bc)
        let replacement=try XCTUnwrap(f.bc.journal.outbox().last);XCTAssertGreaterThan(replacement.dot.counter,old.dot.counter)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("owned-recording-erasure-transport"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        let sender=SyncLibrarySender(library:f.b,cache:f.bc,inbox:inbox,admit:{try $0.validate()},supplementalContent:{_ in XCTFail("Unavailable label publication must not request erased media or declarations");return nil})
        print("RECORDING_RECONCILIATION_PHASE sender-publish")
        guard case .published(let through,let revisions,_,_)=try sender.publish() else {return XCTFail("Owned transfer needs no group review")}
        XCTAssertEqual(through,replacement.dot.counter);XCTAssertEqual(revisions,2)
        XCTAssertEqual(try inbox.revision(replica:receiverID,sequence:old.dot.counter),old)
        XCTAssertEqual(try inbox.supersedingRevision(for:old),replacement)
        XCTAssertNil(try inbox.content(XCTUnwrap(old.content)));XCTAssertNil(try inbox.content(f.original.reference.content))
        print("RECORDING_RECONCILIATION_PHASE receiver-obsolete-header")
        try f.ac.journal.allowPeer(receiverID);var projected=false
        let obsolete=try f.ac.journal.receive(old,contentAvailable:{try inbox.content($0) != nil},supersededBy:{try inbox.supersedingRevision(for:$0)}) {_ in projected=true}
        XCTAssertEqual(obsolete.applied,1);XCTAssertFalse(projected);XCTAssertEqual(try f.ac.journal.expectedOperation(replica:receiverID,sequence:replacement.dot.counter),replacement)
        let packet=try SyncPortableRecord.decode(XCTUnwrap(inbox.content(XCTUnwrap(replacement.content))))
        print("RECORDING_RECONCILIATION_PHASE receiver-replacement")
        let local=try receiveRecording(replacement,packet,f.a,f.ac,media:[:],fetch:{_ in XCTFail("Reconciled unavailable metadata must not fetch old audio");throw OSwindError.invalid("Erased audio cannot be fetched")})
        print("RECORDING_RECONCILIATION_PHASE receiver-finished")
        XCTAssertEqual(try f.ac.journal.cursor(for:receiverID),replacement.dot.counter)
        XCTAssertEqual(try f.ac.resolve(f.metadata.identity,content:nil,admit:{_ in}).body,packet.body)
        XCTAssertEqual(try f.a.get(local)?.title,caption.title);XCTAssertEqual(try f.b.get(f.caption),caption)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));XCTAssertNil(try f.ac.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryNoEditErasureSurvivesFullWorkBudgetAndReopen()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let caption=try XCTUnwrap(f.b.get(f.caption)),current=try XCTUnwrap(f.b.get(f.clip)),queue=try SyncOutgoingWorkQueue.install(catalog:f.bc.catalog)
        try queue.setBudget(1);try eraseRecordingOriginalOnly(f) // Work quota cannot prevent privacy erasure.
        let pending=try recordingRevalidationValue(f.b),processor=try recordingRevalidationProcessor(f.b,f.bc)
        XCTAssertThrowsError(try processor.step(limit:1));XCTAssertEqual(try recordingRevalidationValue(f.b),pending)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));XCTAssertEqual(try f.b.get(f.caption),caption)
        let location=f.b.root;try f.b.close();let reopened=try MemoryStore(root:location);defer {try? reopened.close()}
        let cache=try reopened.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        XCTAssertEqual(try recordingRevalidationValue(reopened),pending)
        try SyncOutgoingWorkQueue.install(catalog:cache.catalog).setBudget(SyncOutgoingWorkQueue.defaultBudget);try drain(reopened,cache,limit:1)
        guard case .source(let body)=try cache.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing reconciled metadata after reopen")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertEqual(try reopened.get(f.caption),caption);XCTAssertEqual(try reopened.get(f.clip),current)
        XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryNoEditRevalidationPolicyDenialPreservesQueuedWorkForRetry()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let caption=try XCTUnwrap(f.b.get(f.caption)),oldHeads=try f.bc.journal.state(for:f.metadata.identity.key).heads
        try eraseRecordingOriginalOnly(f);let denied=try recordingRevalidationProcessor(f.b,f.bc,admit:{record in
            if case .source(let body)=record.body,body.kind == .recordingMetadata {throw SyncPublicationPolicyDenied()}
        })
        XCTAssertEqual(try denied.step(limit:1),.revalidatingRecordings(scanned:1,queued:1))
        let state=try recordingRevalidationValue(f.b)
        XCTAssertThrowsError(try denied.step(limit:1)) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
        XCTAssertEqual(try recordingRevalidationValue(f.b),state);XCTAssertEqual(try f.bc.journal.state(for:f.metadata.identity.key).heads,oldHeads)
        XCTAssertEqual(try f.b.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM personal_sync_work")},1)
        XCTAssertEqual(try f.b.get(f.caption),caption);XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}))
        try drain(f.b,f.bc,limit:1)
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing metadata after policy retry")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertEqual(try f.b.get(f.caption),caption)
    }
    func testRecordingOriginalRecoveryNoEditErasureMarkerFailureRollsBackBodyAndMarkerTogether()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let marker=try recordingRevalidationValue(f.b),outbox=try f.bc.journal.outbox(),record=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in})
        try f.b.withRoutineDatabase {try $0.execute("CREATE TEMP TRIGGER owned_recording_marker_failure BEFORE UPDATE OF value ON main.store_metadata WHEN old.key='recording_wire_reconciliation_v1' BEGIN SELECT RAISE(ABORT,'Owned recording marker refusal'); END")}
        XCTAssertThrowsError(try eraseRecordingOriginalOnly(f)) {XCTAssertTrue(String(describing:$0).contains("Owned recording marker refusal"),"Unexpected rollback probe error: \($0)")}
        try f.b.withRoutineDatabase {try $0.execute("DROP TRIGGER temp.owned_recording_marker_failure")}
        XCTAssertEqual(try recordingRevalidationValue(f.b),marker);XCTAssertEqual(try f.bc.journal.outbox(),outbox)
        XCTAssertEqual(try f.bc.record(f.original.reference,admit:{_ in}),f.original);XCTAssertEqual(try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}),record)
        XCTAssertEqual(try Data(contentsOf:f.b.root.appendingPathComponent(f.mediaPath)),f.bytes)
        try eraseRecordingOriginalOnly(f);try drain(f.b,f.bc)
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing metadata after marker-failure retry")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryNoEditScanUsesCanonicalIndexAndIdleIsReadOnly()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        try f.b.withRoutineDatabase {try $0.execute("DELETE FROM recorded_meeting_details")}
        try eraseRecordingOriginalOnly(f);try drain(f.b,f.bc,limit:1)
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing metadata despite forged display cache")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
        let processor=try recordingRevalidationProcessor(f.b,f.bc)
        try f.b.withRoutineDatabase {db in
            let plan=try db.statement("EXPLAIN QUERY PLAN "+SyncRecordingReconciliation.query(after:true));defer {sqlite3_finalize(plan)}
            db.bind(plan,1,"owned-target");db.bind(plan,2,"owned-caption");sqlite3_bind_int(plan,3,1);var descriptions=[String]()
            while sqlite3_step(plan)==SQLITE_ROW {descriptions.append(db.text(plan,3))}
            XCTAssertTrue(descriptions.contains {$0.contains("USING INDEX memory_recording_names_v1")},descriptions.joined(separator:"; "))
            XCTAssertFalse(descriptions.contains {$0.contains("TEMP B-TREE") || $0.contains("SCAN m")},descriptions.joined(separator:"; "))
            let before=sqlite3_total_changes(db.handle)
            sqlite3_set_authorizer(db.handle,{_,action,table,_,_,_ in
                if [SQLITE_INSERT,SQLITE_UPDATE,SQLITE_DELETE].contains(action) {return SQLITE_DENY}
                if action==SQLITE_READ,let table,String(cString:table)=="memories" {return SQLITE_DENY};return SQLITE_OK
            },nil);defer {sqlite3_set_authorizer(db.handle,nil,nil)}
            XCTAssertEqual(try processor.step(limit:1),.idle);XCTAssertEqual(sqlite3_total_changes(db.handle),before)
        }
    }
    func testRecordingOriginalRecoveryNoEditCursorPreservesLongAndByteDistinctUnicodeTargets()throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let targets=["a"+String(repeating:"\u{0301}",count:2200),"\u{00E9}","e\u{0301}"];var extra=[Memory](),before=[SyncVersionReference]()
        for (index,target) in targets.enumerated() {
            var value=Memory(id:"unicode-revalidation-caption-\(index)",kind:.recordingMetadata,app:"OSwind",title:"Owned unavailable label \(index)",text:"User-authored label")
            value.recordingDetails = .init(scope:try .init(sourceID:target,revision:"authored-missing-evidence"));try f.b.insert(value);extra.append(value)
        }
        try drain(f.b,f.bc)
        for value in extra {let id=try f.bc.catalog.localIdentity(.source,primary:[.text(Data(value.id.utf8))]);before.append(try f.bc.resolve(id,content:nil,admit:{_ in}).reference)}
        try eraseRecordingOriginalOnly(f);let processor=try recordingRevalidationProcessor(f.b,f.bc);var scanned=0,queued=0,finished=false
        for _ in 0..<30 {
            let step=try processor.step(limit:1)
            if case .revalidatingRecordings(let count,let work)=step {XCTAssertLessThanOrEqual(count,1);scanned+=count;queued+=work}
            if step == .idle {finished=true;break}
        }
        XCTAssertTrue(finished);XCTAssertEqual(scanned,4);XCTAssertEqual(queued,1)
        for (index,value) in extra.enumerated() {
            XCTAssertEqual(try f.b.get(value.id),value)
            let identity=try f.bc.catalog.localIdentity(.source,primary:[.text(Data(value.id.utf8))]);XCTAssertEqual(try f.bc.resolve(identity,content:nil,admit:{_ in}).reference,before[index])
            XCTAssertNil(try f.bc.catalog.preparedIdentity(.source,primary:[.text(Data(targets[index].utf8))]))
        }
    }
    func testRecordingOriginalRecoveryNoEditSecondErasureRestartsPartialCanonicalScan()throws {
        let f=try recordingOriginalPeerFixture(secondOriginal:true);defer {try? f.a.close();try? f.b.close()}
        let second=try XCTUnwrap(f.secondary)
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let firstCaption=try XCTUnwrap(f.b.get(f.caption)),secondCaption=try XCTUnwrap(f.b.get(second.caption)),audio=try XCTUnwrap(f.b.get(f.clip))
        try eraseRecordingOriginalOnly(f);let processor=try recordingRevalidationProcessor(f.b,f.bc)
        XCTAssertEqual(try processor.step(limit:1),.revalidatingRecordings(scanned:1,queued:1))
        let partial=try recordingRevalidationValue(f.b)
        let scope=HistoryErasureScope(end:now.addingTimeInterval(1801),kind:.audio),preview=try f.b.previewErasure(scope)
        XCTAssertEqual(preview.matchedSources,0);XCTAssertEqual(preview.matchedHistoricalVersions,1)
        _=try f.b.eraseHistory(scope,expectedToken:preview.token)
        let restarted=try recordingRevalidationValue(f.b);XCTAssertNotEqual(Data(partial.utf8),Data(restarted.utf8))
        let pending=try JSONDecoder().decode(SyncRecordingReconciliation.State.self,from:Data(restarted.utf8));XCTAssertTrue(pending.pending);XCTAssertNil(pending.cursor)
        try drain(f.b,f.bc,limit:1)
        for id in [f.caption,second.caption] {
            let identity=try f.bc.catalog.localIdentity(.source,primary:[.text(Data(id.utf8))])
            guard case .source(let body)=try f.bc.resolve(identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing reconciled name")}
            XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertTrue(body.sourceReferences.isEmpty)
        }
        XCTAssertEqual(try f.b.get(f.caption),firstCaption);XCTAssertEqual(try f.b.get(second.caption),secondCaption);XCTAssertEqual(try f.b.get(f.clip),audio)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));XCTAssertNil(try f.bc.record(second.record.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryNoEditPartialCursorAndQueuedOwnerSurviveReopen()throws {
        let f=try recordingOriginalPeerFixture(secondOriginal:true);defer {try? f.a.close();try? f.b.close()}
        let second=try XCTUnwrap(f.secondary)
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc)
        let scope=HistoryErasureScope(end:now.addingTimeInterval(1801),kind:.audio),preview=try f.b.previewErasure(scope)
        XCTAssertEqual(preview.matchedSources,0);XCTAssertEqual(preview.matchedHistoricalVersions,2)
        _=try f.b.eraseHistory(scope,expectedToken:preview.token)
        let processor=try recordingRevalidationProcessor(f.b,f.bc)
        XCTAssertEqual(try processor.step(limit:1),.revalidatingRecordings(scanned:1,queued:1))
        let partial=try recordingRevalidationValue(f.b),location=f.b.root;try f.b.close()
        let reopened=try MemoryStore(root:location);defer {try? reopened.close()}
        let cache=try reopened.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        XCTAssertEqual(try recordingRevalidationValue(reopened),partial)
        XCTAssertEqual(try reopened.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM personal_sync_work")},1)
        try drain(reopened,cache,limit:1)
        for id in [f.caption,second.caption] {
            let identity=try cache.catalog.localIdentity(.source,primary:[.text(Data(id.utf8))])
            guard case .source(let body)=try cache.resolve(identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing metadata after partial cursor reopen")}
            XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
        }
        XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}));XCTAssertNil(try cache.record(second.record.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryNoEditCancellationInsideCanonicalScanKeepsDurableWork()async throws {
        let f=try recordingOriginalPeerFixture();defer {try? f.a.close();try? f.b.close()}
        try f.b.setFavorite(f.caption,value:true);try drain(f.b,f.bc);try eraseRecordingOriginalOnly(f)
        let before=try recordingRevalidationValue(f.b),processor=try recordingRevalidationProcessor(f.b,f.bc),gate=RecordingRevalidationCancellationGate()
        defer {withExtendedLifetime(gate) {}}
        try f.b.withRoutineDatabase {db in
            XCTAssertEqual(sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,statement,_ in
                if let context,let statement,let sql=sqlite3_sql(OpaquePointer(statement)),String(cString:sql)==SyncRecordingReconciliation.query(after:false) {
                    Unmanaged<RecordingRevalidationCancellationGate>.fromOpaque(context).takeUnretainedValue().pause()
                }
                return 0
            },Unmanaged.passUnretained(gate).toOpaque()),SQLITE_OK)
        }
        let task=Task.detached {try f.b.withRoutineDatabase {_ in try processor.step(limit:1)}}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();gate.release()
        do {_=try await task.value;XCTFail("A cancelled recording scan must not advance its durable cursor")}catch {XCTAssertTrue(error is CancellationError,"Unexpected scan cancellation error: \(error)")}
        try f.b.withRoutineDatabase {XCTAssertEqual(sqlite3_trace_v2($0.handle,0,nil,nil),SQLITE_OK)}
        XCTAssertEqual(try recordingRevalidationValue(f.b),before)
        XCTAssertEqual(try f.b.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM personal_sync_work")},0)
        XCTAssertNil(try f.bc.record(f.original.reference,admit:{_ in}));try drain(f.b,f.bc,limit:1)
        guard case .source(let body)=try f.bc.resolve(f.metadata.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing metadata after cancelled scan retry")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
    }
}
