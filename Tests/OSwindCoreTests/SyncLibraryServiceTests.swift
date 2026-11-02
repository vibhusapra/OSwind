import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    struct ServicePair:Sendable {
        let a:SyncLibraryService,b:SyncLibraryService,receiver:MemoryStore
        let transport:SyncObjectFolder,localA:SyncObjectFolder,localB:SyncObjectFolder,secret:SyncGroupSecret
    }
    func makeServicePair()throws->ServicePair {
        var retained=false
        let other="00000000-0000-0000-0000-000000009602",secret=SyncGroupSecret()
        let receiver=try MemoryStore(root:root.appendingPathComponent("service-receiver"))
        defer {if !retained {try? receiver.close()}}
        let transport=try SyncObjectFolder.create(at:root.deletingLastPathComponent().appendingPathComponent("owned-service-shared-"+UUID().uuidString),secret:secret,group:group,epoch:epoch)
        defer {if !retained {transport.close();try? FileManager.default.removeItem(at:transport.root)}}
        let localA=try SyncObjectFolder.create(at:root.appendingPathComponent("images/service-local-a"),secret:secret,group:group,epoch:epoch)
        defer {if !retained {localA.close()}}
        let localB=try SyncObjectFolder.create(at:receiver.root.appendingPathComponent("images/service-local-b"),secret:secret,group:group,epoch:epoch)
        defer {if !retained {localB.close()}}
        let a=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:[other],transport:transport,inbox:localA)
        defer {if !retained {try? a.stop()}}
        let b=try SyncLibraryService.install(library:receiver,replica:other,group:group,epoch:epoch,peers:[replica],transport:transport,inbox:localB)
        retained=true
        return .init(a:a,b:b,receiver:receiver,transport:transport,localA:localA,localB:localB,secret:secret)
    }
    func finishServicePair(_ f:ServicePair) {
        try? f.a.stop();try? f.b.stop();try? f.receiver.close();f.transport.close();f.localA.close();f.localB.close();try? FileManager.default.removeItem(at:f.transport.root)
    }
    func withServicePair(_ body:(ServicePair)throws->Void)throws {
        let f=try makeServicePair();defer {finishServicePair(f)};try body(f)
    }
    func withServicePairAsync(_ body:(ServicePair)async throws->Void)async throws {
        let f=try makeServicePair();defer {finishServicePair(f)};try await body(f)
    }
    @discardableResult func serviceReady(_ service:SyncLibraryService,limit:Int=2,networkEnabled:Bool=true)throws->SyncLibraryServiceStep {
        for _ in 0..<300 {
            let step=try service.tick(limit:limit,networkEnabled:networkEnabled)
            switch step {case .preparing,.reviewingPolicy:continue;default:return step}
        };throw OSwindError.invalid("Owned service did not finish bounded preparation")
    }
    func serviceCount(_ store:MemoryStore,_ table:String)throws->Int {try store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM "+table)}}

    func testServiceTransfersRealThirteenKindGraphWithoutCallerSuppliedPolicyOrMediaHooks()throws {
        try seedGraph()
        let expected=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {($0.rawValue,try serviceCount(store,$0.rawValue))})
        try withServicePair {f in
            _=try serviceReady(f.a);_=try serviceReady(f.b)
            for _ in 0..<40 {_=try serviceReady(f.a);_=try serviceReady(f.b)}
            for table in SyncCanonicalTable.allCases {XCTAssertEqual(try serviceCount(f.receiver,table.rawValue),expected[table.rawValue],table.rawValue)}
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_changes"),0)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_bindings"),1)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_jobs"),0)
            try f.receiver.withRoutineDatabase {db in
                XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM routines WHERE enabled!=0"),0)
                let values=try f.b.cache.journal.outbox();XCTAssertTrue(values.isEmpty,"Peer projection must not author echo operations")
                XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),try f.a.cache.journal.outbox(limit:128).last?.dot.counter)
            }
        }
    }

    func testServiceTransfersActualImageBytesAndRefusesChangedContentAddress()throws {
        let png=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII="))
        try png.write(to:root.appendingPathComponent("images/service.png"))
        try store.insert(Memory(id:"service-image",timestamp:now,kind:.screen,app:"Owned",text:"Owned image",imagePath:"images/service.png"))
        try withServicePair {f in
            _=try serviceReady(f.a);_=try serviceReady(f.b)
            let projected=try f.receiver.withRoutineDatabase {db -> Memory in
                let row=try db.statement("SELECT payload FROM memories");defer {sqlite3_finalize(row)}
                guard sqlite3_step(row)==SQLITE_ROW,let bytes=sqlite3_column_blob(row,0) else {throw OSwindError.invalid("Missing owned projected image")}
                return try JSONDecoder().decode(Memory.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(row,0))))
            }
            let path=try XCTUnwrap(projected.imagePath)
            XCTAssertTrue(path.hasPrefix("images/sync-"));XCTAssertEqual(try Data(contentsOf:f.receiver.root.appendingPathComponent(path)),png)
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),1)
            let reference=try XCTUnwrap(f.a.cache.journal.outbox().first?.content)
            let record=try SyncPortableRecord.decode(XCTUnwrap(f.transport.content(reference)))
            guard case .source(let source)=record.body else {return XCTFail("Missing source")}
            try Data("changed retained bytes".utf8).write(to:f.receiver.root.appendingPathComponent(path))
            let media=SyncServiceMedia(library:f.receiver,inbox:f.localB,policy:.init(settings:AppSettings()))
            XCTAssertThrowsError(try media.paths(record.reference,source.media,fetch:{try XCTUnwrap(f.transport.content($0))}))
        }
    }

    func testServiceCurrentSavedPrivacyDeniesSecretAndExcludedBrowserBeforePublication()throws {
        try withServicePair {f in
            var settings=AppSettings();settings.privacy.excludedDomains=["owned.example.test"];try settings.save(root:root)
            try store.insert(Memory(id:"blocked",timestamp:now,kind:.screen,app:"Safari",bundleID:"com.apple.Safari",title:"Owned",url:"https://owned.example.test/private",text:"Owned blocked source"))
            XCTAssertEqual(try serviceReady(f.a),.waitingForPolicy(1))
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,0)
            XCTAssertTrue(try f.a.cache.journal.outbox().isEmpty)
            settings.privacy.excludedDomains=[];try settings.save(root:root)
            _=try serviceReady(f.a)
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,1)
            try store.insert(Memory(id:"secret",timestamp:now,kind:.note,app:"Owned",text:"password=owned-authored-secret-value"))
            XCTAssertEqual(try serviceReady(f.a),.waitingForPolicy(1))
            XCTAssertEqual(try f.transport.serviceHead(replica:replica)?.through,1)
        }
    }

    func testServiceRestartUsesDurableSendAndReceiveCursorsAndInvalidatesOldWorker()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a);_=try serviceReady(f.b)
            let replacement=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:f.a.peers,transport:f.transport,inbox:f.localA)
            defer {try? replacement.stop()}
            XCTAssertThrowsError(try f.a.tick());try f.a.stop()
            guard case .transferred(let sent,_,_)=try serviceReady(replacement) else {return XCTFail("Replacement did not resume")};XCTAssertEqual(sent,0)
            try seed("offline-after-replacement","Owned offline change")
            _=try serviceReady(replacement);_=try serviceReady(f.b)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),2)
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),2)
            try replacement.stop();XCTAssertThrowsError(try replacement.tick())
        }
    }

    func testServiceRejectsAuthenticatedHeadRollbackAndYieldsRemoteEraseBeforeExport()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a);_=try serviceReady(f.b)
            let old=try XCTUnwrap(f.transport.serviceHead(replica:replica))
            XCTAssertThrowsError(try f.transport.publishServiceHead(.init(group:group,epoch:epoch,replica:replica,through:0,collectionCounter:0)))
            XCTAssertEqual(try f.transport.serviceHead(replica:replica),old)
            _=try store.wipeLibrary()
            let proposal=try serviceReady(f.a)
            guard case .needsGroupReview(let control)=proposal else {return XCTFail("Local wipe must require review")}
            let approved=try store.withRoutineDatabase {db in try SyncCollectionHistory(database:db,replica:replica).approveGroupErase(journal:f.a.cache.journal,counter:control.counter,expectedEra:control.era)}
            // The native wipe invalidates publication authority; the service
            // must not revive its old queue merely because review was approved.
            XCTAssertThrowsError(try f.a.tick())
            try f.transport.publishCollectionControl(approved)
            try f.transport.publishServiceHead(.init(group:group,epoch:epoch,replica:replica,through:old.through,collectionCounter:approved.counter))
            try f.receiver.insert(Memory(id:"unsent",timestamp:now,kind:.note,app:"Owned",text:"password=owned-blocked-unsent-value"))
            guard case .needsNativeCollectionRetirement(let received)=try serviceReady(f.b) else {return XCTFail("Worker must yield to the lifecycle owner")}
            XCTAssertEqual(received,approved);XCTAssertNotNil(try f.receiver.get("unsent"))
            XCTAssertEqual(try f.transport.serviceHead(replica:f.b.cache.journal.replica)?.through,0)
            let oldQueue=try f.receiver.withRoutineDatabase {_ in try SyncPublicationQueue.install(cache:f.b.cache)}
            try f.b.stop()
            XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport).receive(creator:replica,counter:approved.counter),.applied)
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:approved))
            XCTAssertTrue(try f.receiver.retryLibraryWipeCleanup().cleanupComplete)
            XCTAssertThrowsError(try oldQueue.context())
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.localB.root.path),"Native cleanup must remove the local encrypted spool as well")
            f.localB.close()
            let freshInbox=try SyncObjectFolder.create(at:f.localB.root,secret:f.secret,group:group,epoch:epoch)
            defer {freshInbox.close()}
            let resumed=try SyncLibraryService.install(library:f.receiver,replica:f.b.cache.journal.replica,group:group,epoch:epoch,peers:[replica],transport:f.transport,inbox:freshInbox,resumeAfterReceivedCollection:approved)
            defer {try? resumed.stop()}
            XCTAssertThrowsError(try oldQueue.context(),"Renewal must never revive an existing queue value")
            try f.receiver.insert(Memory(id:"fresh-after-group",timestamp:now,kind:.note,app:"Owned",text:"Owned fresh after group retirement"))
            guard case .transferred=try serviceReady(resumed) else {return XCTFail("Fresh generation must resume")}
            XCTAssertNotNil(try f.receiver.get("fresh-after-group"));XCTAssertNil(try f.receiver.get("unsent"))
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:resumed.cache,library:f.receiver,control:approved),"Do not replace live authority twice")
        }
    }

    func testServiceTransfersRealAudioAndVideoAndHonorsIndependentReceiverRetention()throws {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"WorkflowPriming",withExtension:nil))
        let wav=try Data(contentsOf:fixture.appendingPathComponent("source.wav")),video=try Data(contentsOf:fixture.appendingPathComponent("unaligned.mp4"))
        try wav.write(to:root.appendingPathComponent("audio/service.wav"));try video.write(to:root.appendingPathComponent("video/service.mp4"))
        var speech=Memory(id:"service-speech",timestamp:now,kind:.audio,app:"Owned",text:"Owned speech",audioPath:"audio/service.wav")
        speech.transcript = .init(text:"Owned speech",duration:0.25,segments:[.init(start:0,end:0.25,text:"Owned speech")],model:"owned-local")
        var replay=Memory(id:"service-replay",timestamp:now,kind:.screen,app:"Owned",text:"Owned replay")
        replay.videoPath="video/service.mp4";replay.visualRecording = .init(duration:0.25,width:1280,height:720,codec:"h264",hardwareRequired:false,frames:[.init(time:0,text:"Owned replay",regions:[])])
        try store.insert(speech);try store.insert(replay)
        var settings=AppSettings();settings.retainAudio=true;settings.visualCaptureMode = .replay;try settings.save(root:root)
        try withServicePair {f in
            _=try serviceReady(f.a)
            XCTAssertThrowsError(try serviceReady(f.b)) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),0);XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),0)
            try settings.save(root:f.receiver.root)
            _=try serviceReady(f.b)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),2)
            try f.receiver.withRoutineDatabase {db in
                let row=try db.statement("SELECT payload FROM memories ORDER BY kind");defer {sqlite3_finalize(row)}
                while sqlite3_step(row)==SQLITE_ROW {
                    let memory=try JSONDecoder().decode(Memory.self,from:Data(bytes:sqlite3_column_blob(row,0)!,count:Int(sqlite3_column_bytes(row,0))))
                    if let audio=memory.audioPath {XCTAssertEqual(try Data(contentsOf:f.receiver.root.appendingPathComponent(audio)),wav);XCTAssertEqual(memory.transcript,speech.transcript)}
                    if let clip=memory.videoPath {XCTAssertEqual(try Data(contentsOf:f.receiver.root.appendingPathComponent(clip)),video);XCTAssertEqual(memory.visualRecording,replay.visualRecording)}
                }
            }
        }
    }

    func testServiceMediaStreamsAcrossChunkBoundaryAndFailedAdoptionLeavesNoNativeSource()throws {
        let bytes=Data(repeating:173,count:SyncMediaManifest.chunkBytes+17)
        try bytes.write(to:root.appendingPathComponent("images/large-owned.png"))
        let memory=Memory(id:"large-owned",timestamp:now,kind:.screen,app:"Owned",text:"Owned multichunk byte fixture",imagePath:"images/large-owned.png")
        try withServicePair {f in
            let media=SyncServiceMedia(library:store,inbox:f.localA,policy:.init(settings:AppSettings()))
            let manifest=try XCTUnwrap(media.prepare(memory).first)
            XCTAssertEqual(manifest.chunks.map(\.bytes),[Int64(SyncMediaManifest.chunkBytes),17])
            let reference=SyncVersionReference(identity:try .init(table:.source,origin:replica,lifetime:epoch),content:try .init(data:Data("owned media-only adapter reference".utf8)))
            let incoming=SyncServiceMedia(library:f.receiver,inbox:f.localB,policy:.init(settings:AppSettings()))
            var fetched=0
            XCTAssertThrowsError(try incoming.paths(reference,[manifest],fetch:{ref in
                fetched+=1;if fetched==2 {throw OSwindError.unavailable("Owned interrupted delivery")};return try XCTUnwrap(f.localA.content(ref))
            }))
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),0)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:f.receiver.root.appendingPathComponent("images").path).contains(where:{$0.hasPrefix("sync-") || $0.hasPrefix(".sync-stage-")}))
            let paths=try incoming.paths(reference,[manifest],fetch:{try XCTUnwrap(f.localA.content($0))})
            XCTAssertEqual(try Data(contentsOf:f.receiver.root.appendingPathComponent(XCTUnwrap(paths[.image]))),bytes)
        }
    }

    func testServiceSchedulerOwnsBackgroundDeliveryAndStopJoinsWorker()async throws {
        try seed()
        // The synchronous pair scope owns file lifetimes; coordinate the async
        // driver without letting teardown race a detached worker.
        let other="00000000-0000-0000-0000-000000009603",secret=SyncGroupSecret()
        let transport=try SyncObjectFolder.create(at:root.deletingLastPathComponent().appendingPathComponent("owned-scheduled-shared-"+UUID().uuidString),secret:secret,group:group,epoch:epoch)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("images/scheduled-local"),secret:secret,group:group,epoch:epoch)
        defer {transport.close();inbox.close();try? FileManager.default.removeItem(at:transport.root)}
        let service=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:[other],transport:transport,inbox:inbox)
        let scheduler=try SyncLibraryScheduler(service:service,schedule:.init(activeSeconds:0.001,idleSeconds:0.01,retrySeconds:0.01))
        try await scheduler.start()
        var delivered=false
        for _ in 0..<500 {
            if try transport.serviceHead(replica:replica)?.through==1 {delivered=true;break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        try await scheduler.stop()
        XCTAssertTrue(delivered);let state=await scheduler.state;XCTAssertEqual(state,.stopped)
        XCTAssertThrowsError(try service.tick())
        do {try await scheduler.start();XCTFail("Stopped scheduler cannot create an unowned second worker")}catch {}
        let schedule=SyncLibrarySchedule()
        XCTAssertEqual(schedule.delay(.transferred(sent:0,received:0,pendingPublications:0),lowPower:false,thermalLimited:false),15)
        XCTAssertEqual(schedule.delay(.transferred(sent:0,received:0,pendingPublications:0),lowPower:true,thermalLimited:false),60)
        XCTAssertEqual(schedule.delay(.transferred(sent:0,received:0,pendingPublications:0),lowPower:false,thermalLimited:true),120)
    }

    func testServiceSenderSettingsFencePreventsProviderWriteAfterPolicySave()throws {
        try install();try seed();_=try finish()
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        let transport=try SyncObjectFolder.create(at:root.appendingPathComponent("owned-fence-transport"),secret:SyncGroupSecret(),group:group,epoch:epoch)
        defer {transport.close()}
        var saved=false
        var sender=SyncLibrarySender(library:store,cache:cache,inbox:transport,admit:{_ in
            if !saved {saved=true;var settings=AppSettings();settings.privacy.retainImages=false;try settings.save(root:self.root)}
        },supplementalContent:{_ in nil})
        sender.publicationFence={write in try snapshot.withCurrent(root:self.root,policy:snapshot.settings.privacy,write)}
        XCTAssertThrowsError(try sender.publish())
        XCTAssertTrue(saved)
        let operation=try XCTUnwrap(cache.journal.outbox().first)
        XCTAssertNil(try transport.revision(replica:replica,sequence:operation.dot.counter))
        XCTAssertNil(try transport.content(XCTUnwrap(operation.content)))
    }

    func testServicePolicyChecksContentOfEveryKindWithoutTreatingNumericIdentityAsSecret()throws {
        try seedGraph();try install();_=try finish()
        let policy=SyncServicePolicy(settings:AppSettings()),all=try records()
        XCTAssertEqual(Set(all.map(\.identity.table)),Set(SyncCanonicalTable.allCases))
        for record in all {XCTAssertNoThrow(try policy.admit(record),record.identity.table.rawValue)}
        let secret="password=owned-never-publish-value"
        // Select one free content field in each content-bearing wire kind.
        let fields:[SyncCanonicalTable:String]=[.source:"text",.conversation:"title",.turn:"question",.conversationCitation:"match",.recapCitation:"match",.routine:"prompt",.routineRun:"message",.entity:"detail",.entityAlias:"label",.entityMention:"surface",.entityRejection:"key"]
        var rejected=Set<SyncCanonicalTable>()
        for record in all {
            guard let field=fields[record.identity.table] else {continue}
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:record.encoded()) as? [String:Any])
            func replace(_ value:Any)->Any {
                if var map=value as? [String:Any] {
                    if map[field] != nil {
                        map[field]=secret
                        if record.identity.table == .entityAlias {map["key"]=EntityLabel.key(secret)}
                        if record.identity.table == .entityMention {map["passage"]=["start":0,"length":secret.utf16.count]}
                    }
                    else {for (key,child) in map {map[key]=replace(child)}}
                    return map
                };return value
            }
            object["body"]=replace(try XCTUnwrap(object["body"]))
            let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
            let changed=try JSONDecoder().decode(SyncPortableRecord.self,from:bytes)
            try changed.validate();XCTAssertNotEqual(changed,record)
            XCTAssertThrowsError(try policy.admit(changed),record.identity.table.rawValue) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
            rejected.insert(record.identity.table)
        }
        XCTAssertEqual(rejected,Set(fields.keys))
        var speech=Memory(id:"owned-speech-secret",text:"Owned otherwise ordinary speech")
        speech.transcript = .init(text:speech.text,duration:1,segments:[.init(start:0,end:1,text:"my password is an owned value")],model:"owned")
        XCTAssertThrowsError(try policy.admit(speech)) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
    }

    func testServiceRefusesNativeLibraryInSharedSpaceAndSpoolOutsideWipeInventory()throws {
        let secret=SyncGroupSecret(),shared=try SyncObjectFolder.create(at:root.appendingPathComponent("bad-shared"),secret:secret,group:group,epoch:epoch)
        let local=try SyncObjectFolder.create(at:root.appendingPathComponent("bad-local"),secret:secret,group:group,epoch:epoch)
        defer {shared.close();local.close()}
        XCTAssertThrowsError(try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:[],transport:shared,inbox:local))
        XCTAssertEqual(try n("SELECT enabled FROM personal_sync_capture"),0,"Refuse unsafe roots before activating capture")
    }

    func testServiceReopensBothLibrariesAndEncryptedSpoolsAfterPartialGraphDelivery()throws {
        try seedGraph()
        let expected=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {($0.rawValue,try serviceCount(store,$0.rawValue))})
        try withServicePair {f in
            for _ in 0..<40 {_=try serviceReady(f.a,limit:1)}
            _=try serviceReady(f.b,limit:1)
            let partial=try XCTUnwrap(f.b.cache.journal.cursor(for:replica))
            XCTAssertGreaterThan(partial,0);XCTAssertLessThan(partial,try XCTUnwrap(f.transport.serviceHead(replica:replica)?.through))
            try f.a.stop();try f.b.stop();try store.close();try f.receiver.close();f.localA.close();f.localB.close()
            store=try MemoryStore(root:root)
            let receiver=try MemoryStore(root:f.receiver.root)
            let localA=try SyncObjectFolder.open(at:f.localA.root,secret:f.secret,group:group,epoch:epoch)
            let localB=try SyncObjectFolder.open(at:f.localB.root,secret:f.secret,group:group,epoch:epoch)
            defer {try? receiver.close();localA.close();localB.close()}
            let a=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:f.a.peers,transport:f.transport,inbox:localA)
            let b=try SyncLibraryService.install(library:receiver,replica:f.b.cache.journal.replica,group:group,epoch:epoch,peers:[replica],transport:f.transport,inbox:localB)
            defer {try? a.stop();try? b.stop()}
            XCTAssertEqual(try b.cache.journal.cursor(for:replica),partial)
            for _ in 0..<40 {_=try serviceReady(a,limit:2);_=try serviceReady(b,limit:2)}
            for table in SyncCanonicalTable.allCases {XCTAssertEqual(try serviceCount(receiver,table.rawValue),expected[table.rawValue],table.rawValue)}
            XCTAssertEqual(try serviceCount(receiver,"personal_sync_publication_jobs"),0)
            XCTAssertEqual(try serviceCount(receiver,"personal_sync_publication_bindings"),1)
            XCTAssertEqual(try serviceCount(receiver,"personal_sync_changes"),0)
            if let destination=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_SERVICE_ROOT"] {
                let output=URL(fileURLWithPath:destination,isDirectory:true).appendingPathComponent("reopened-all13-"+UUID().uuidString.lowercased())
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try snapshotNativeCollectionBefore(store,to:output.appendingPathComponent("producer.sqlite"))
                try snapshotNativeCollectionBefore(receiver,to:output.appendingPathComponent("receiver.sqlite"))
                let receipt:[String:Any]=["tables":expected,"partialCursor":partial,"finalCursor":try XCTUnwrap(b.cache.journal.cursor(for:replica)),"peerOutbox":try b.cache.journal.outbox().count,"publicationJobs":try serviceCount(receiver,"personal_sync_publication_jobs"),"publicationBindings":try serviceCount(receiver,"personal_sync_publication_bindings")]
                try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
            }
        }
    }

    func testServiceDiscoversDelayedDeclarationAfterCursorProgressWithoutAnotherPeerOperation()throws {
        try seedGraph()
        try withServicePair {f in
            for _ in 0..<40 {_=try serviceReady(f.a)}
            let operations=try f.a.cache.journal.outbox(),declaration=try XCTUnwrap(operations.compactMap(\.publication).first)
            XCTAssertLessThan(declaration.bytes,Int64(SyncCipherContext.maximumPlaintextBytes))
            let cipher=try SyncCipherContext(secret:f.secret,group:group,epoch:epoch,purpose:.contentChunk)
            let token=try cipher.token(for:Data("OSwind.sync.content.v1\0\(declaration.sha256)\0\(declaration.bytes)\00".utf8))
            let packet=f.transport.root.appendingPathComponent("objects/\(token.prefix(2))/\(token)"),hidden=root.appendingPathComponent("owned-delayed-declaration")
            try FileManager.default.moveItem(at:packet,to:hidden)
            for _ in 0..<40 {_=try serviceReady(f.b)}
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),operations.last?.dot.counter)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_jobs"),1)
            XCTAssertEqual(try serviceCount(f.receiver,"chat_turns"),0)
            try FileManager.default.moveItem(at:hidden,to:packet)
            _=try serviceReady(f.b)
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),operations.last?.dot.counter)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_jobs"),0)
            XCTAssertEqual(try serviceCount(f.receiver,"chat_turns"),1)
            XCTAssertEqual(try serviceCount(f.receiver,"chat_sources"),1)
        }
    }
}
