import XCTest
import CSQLite
@testable import OSwindCore

private struct RecordingOriginalPeerFixture {
    let a:MemoryStore,b:MemoryStore,ac:SyncVersionStore,bc:SyncVersionStore
    let original:SyncPortableRecord,metadata:SyncPortableRecord,latestAudio:SyncRevision
    let clip:String,caption:String,handle:String,mediaPath:String,bytes:Data
}
extension SyncIncomingSourceTests {
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
    private func recordingOriginalPeerFixture()throws->RecordingOriginalPeerFixture {
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
        audio.text="Current independent authored speech";audio.app="Current authored app";audio.timestamp=now.addingTimeInterval(3600);try a.insert(audio);try drain(a,ac)
        let latest=try XCTUnwrap(ac.journal.outbox().last {$0.key==audioOp.key && $0.content != audioOp.content}),current=try packet(latest,ac)
        _=try receiveRecording(latest,current,b,bc,media:[.audio:receiverPath],fetch:{_ in original})
        try b.withRoutineDatabase {db in
            let row=try db.statement("DELETE FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)};db.bind(row,1,try original.identity.key.digest);db.bind(row,2,try original.reference.content.sha256);try db.done(row);XCTAssertEqual(sqlite3_changes(db.handle),1)
        }
        XCTAssertNil(try bc.record(original.reference,admit:{_ in}));XCTAssertEqual(try b.get(clip)?.text,audio.text)
        ready=true;return .init(a:a,b:b,ac:ac,bc:bc,original:original,metadata:metadata,latestAudio:latest,clip:clip,caption:caption,handle:retained.handle,mediaPath:receiverPath,bytes:bytes)
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
}
