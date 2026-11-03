import XCTest
import CSQLite
@testable import OSwindCore

final class PersonalSyncMembershipUpdateTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),pairings=[PersonalSyncPairing](),sessions=[PersonalSyncSession](),changes=[PersonalSyncMembershipChange]()
    private let storage=PairingTestStorage(),now=Date(timeIntervalSince1970:1_800_000_000)
    private var nativeBackend:NativeWriterKeychainFixture?
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"d",count:64))
    private var serial=0
    private var environment:SyncNativeWriterEnvironment {
        if let nativeBackend {let native=SyncNativeWriterEnvironment.native;return .init(stateRoot:native.stateRoot,machine:native.machine,storage:{_ in nativeBackend})}
        return .init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})
    }
    private struct Fixture {
        let ownerStore:MemoryStore,peerStore:MemoryStore,joining:PersonalSyncPairing
        let ownerSession:PersonalSyncSession,peerSession:PersonalSyncSession
        let firstCertificate:SyncMembershipCertificate,request:String,fingerprint:String,folder:URL
        var exporting:PersonalSyncPairing?
    }
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-membership-update-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    override func tearDown()async throws {
        for session in sessions {try await session.stop()}
        try changes.forEach {try $0.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()}
        try nativeBackend?.cleanup()
        try FileManager.default.removeItem(at:root)
    }
    private func store(_ path:URL)throws->MemoryStore {
        let value=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value
    }
    private func pair(_ store:MemoryStore)throws->PersonalSyncPairing {
        let env=environment,value=try PersonalSyncPairing(store:store,stateRoot:env.stateRoot,machine:env.machine,storage:env.storage(.loginKeychain));pairings.append(value);return value
    }
    private func fixture(advanceOwner:Bool=true)async throws->Fixture {
        serial+=1;let base=root.appendingPathComponent("fixture-\(serial)"),ownerStore=try store(base.appendingPathComponent("owner")),peerStore=try store(base.appendingPathComponent("peer")),owner=try pair(ownerStore),peer=try pair(peerStore)
        _=try owner.createGroup(deviceName:"Owned desk",now:now)
        let fingerprint=try XCTUnwrap(owner.status().rootFingerprint),first=try SyncMembershipUpdateRequest.decode(Data(owner.membershipUpdateRequest().utf8)).certificate
        let request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned travel",now:now).request)
        _=try peer.acceptResponse(owner.approve(owner.reviewRequest(request,now:now),now:now),trustedRootFingerprint:fingerprint,now:now)
        let folder=base.appendingPathComponent("provider"),ownerSession=try owner.prepareSession(sharedFolder:folder,createSharedFolder:true),peerSession=try peer.prepareSession(sharedFolder:folder)
        sessions += [ownerSession,peerSession]
        let joining=try pair(store(base.appendingPathComponent("joining"))),joiningRequest=try XCTUnwrap(joining.requestJoin(deviceName:"Owned third Mac",now:now).request)
        var fixture=Fixture(ownerStore:ownerStore,peerStore:peerStore,joining:joining,ownerSession:ownerSession,peerSession:peerSession,firstCertificate:first,request:joiningRequest,fingerprint:fingerprint,folder:folder)
        if advanceOwner {
            let review=try await ownerSession.reviewOwnerAddition(joiningRequest,now:now);try await ownerSession.stop()
            let time=now,change=try await ownerSession.ownerChangeAfterStopping(review,clock:{time});changes.append(change)
            let response=try XCTUnwrap(change.apply(clock:{self.now}));try change.close()
            _=try joining.acceptResponse(response.response,trustedRootFingerprint:fingerprint,now:now)
            fixture.exporting=try pair(store(ownerStore.root))
        }
        return fixture
    }
    private func page(_ fixture:Fixture)async throws->String {
        let request=try await fixture.peerSession.membershipUpdateRequest()
        return try XCTUnwrap(fixture.exporting).membershipUpdatePage(for:request).map {$0} ?? {throw OSwindError.invalid("Owned successor page missing")}()
    }
    private func change(_ session:PersonalSyncSession,_ review:PersonalSyncMembershipReview)async throws->PersonalSyncMembershipChange {
        let value=try await session.membershipChangeAfterStopping(review);changes.append(value);return value
    }
    private func refused(_ session:PersonalSyncSession,_ review:PersonalSyncMembershipReview)async {
        do {_=try await change(session,review);XCTFail("A live, stale, consumed or foreign membership review must refuse")}
        catch {}
    }
    private func pairingID(_ store:MemoryStore)throws->String {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1'");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned pairing handle missing")}
            let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(db.text(row,0).utf8)) as? [String:Any]);return try XCTUnwrap(object["id"] as? String)
        }
    }
    private func originalPrivateFields(_ account:String,backend:NativeWriterKeychainFixture)throws->[String:String] {
        let envelope=try XCTUnwrap(JSONSerialization.jsonObject(with:backend.read(id:account)) as? [String:Any])
        let material=try XCTUnwrap(Data(base64Encoded:XCTUnwrap(envelope["material"] as? String))),value=try XCTUnwrap(JSONSerialization.jsonObject(with:material) as? [String:Any])
        var result=[String:String]()
        for key in ["replica","signingPrivate","agreementPrivate","groupSecret"] {result[key]=try XCTUnwrap(value[key] as? String)}
        if let owner=value["ownerPrivate"] {result["ownerPrivate"]=try XCTUnwrap(owner as? String)}
        return result // In-memory only; assertions never print these values.
    }
    private func futurePage(_ f:Fixture)throws->String {
        let envelope=try XCTUnwrap(JSONSerialization.jsonObject(with:storage.read(id:pairingID(f.ownerStore))) as? [String:Any])
        let raw=try XCTUnwrap(Data(base64Encoded:XCTUnwrap(envelope["material"] as? String))),authority=try XCTUnwrap(SyncCredentialMaterial.decodeFromKeychain(raw).owner)
        let future=try authority.admitting(SyncJoinRequest.decode(Data(f.request.utf8),now:now),now:now)
        return String(decoding:try SyncMembershipRefresh(base:authority.certificate,updates:[future.certificate]).encoded(),as:UTF8.self)
    }
    func testPublicRequestAndPageExposeOnlySignedHistoryAndExactCurrentReturnsNil()async throws {
        let f=try await fixture(),request=try await f.peerSession.membershipUpdateRequest(),decoded=try SyncMembershipUpdateRequest.decode(Data(request.utf8)),page=try await page(f),proof=try SyncMembershipRefresh.decode(Data(page.utf8))
        XCTAssertEqual(decoded.certificate.body.members.count,2);XCTAssertEqual(proof.base,decoded.certificate);XCTAssertEqual(proof.head.body.members.count,3)
        XCTAssertEqual(try proof.advance(from:decoded.certificate),proof.head)
        let exporter=try XCTUnwrap(f.exporting);XCTAssertNil(try exporter.membershipUpdatePage(for:exporter.membershipUpdateRequest()))
        for text in [request,page] {for key in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate","pairingBefore","materialBefore"] {XCTAssertFalse(text.contains("\""+key+"\""))}}
    }
    func testPublicRequestRejectsNoncanonicalUnknownFormatTamperingAndOversize()async throws {
        let f=try await fixture(),request=try await f.peerSession.membershipUpdateRequest(),exporter=try XCTUnwrap(f.exporting)
        XCTAssertThrowsError(try exporter.membershipUpdatePage(for:request+" "))
        XCTAssertThrowsError(try exporter.membershipUpdatePage(for:String(repeating:" ",count:SyncMembershipUpdateRequest.maximumBytes+1)))
        for field in ["format","version","unknown","certificate"] {
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(request.utf8)) as? [String:Any])
            switch field {
            case "format":object[field]="untrusted"
            case "version":object[field]=2
            case "unknown":object[field]=true
            default:var certificate=try XCTUnwrap(object[field] as? [String:Any]);certificate["signature"]=Data(repeating:0,count:64).base64EncodedString();object[field]=certificate
            }
            let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
            XCTAssertThrowsError(try exporter.membershipUpdatePage(for:String(decoding:bytes,as:UTF8.self)),field)
        }
    }
    func testExactReviewedPeerStopsBeforeRetainedIntentAndAppliesWithoutJoiningResponse()async throws {
        let f=try await fixture(),review=try await f.peerSession.reviewMembershipUpdate(page(f)),saved=storage.values
        XCTAssertEqual(review.rootFingerprint,f.fingerprint);XCTAssertEqual(review.currentMemberCount,2);XCTAssertEqual(review.updatedMemberCount,3);XCTAssertEqual(review.addedDeviceNames,["Owned third Mac"])
        await refused(f.peerSession,review);XCTAssertTrue(storage.values==saved)
        try await f.peerSession.stop();let operation=try await change(f.peerSession,review)
        XCTAssertTrue(operation.belongs(to:f.peerStore));XCTAssertTrue(storage.values==saved,"Draft wrote a private intent before the caller retained it")
        XCTAssertNil(try operation.apply());let admitted=storage.values
        XCTAssertNil(try operation.apply());XCTAssertTrue(storage.values==admitted);await refused(f.peerSession,review)
        try operation.close();XCTAssertTrue(f.peerStore.isClosed)
        let fresh=try store(f.peerStore.root),paired=try pair(fresh);try review.validateReopenedStore(fresh)
        XCTAssertEqual(try paired.status().memberNames.count,3);XCTAssertEqual(Set(storage.values.keys),Set(saved.keys))
        try fresh.insert(Memory(id:"after-update",text:"Original peer can write after exact membership catch-up"));XCTAssertNotNil(try fresh.get("after-update"))
    }
    func testLatestReviewInvalidatesPriorTokenWithoutConsumingCurrentOne()async throws {
        let f=try await fixture(),page=try await page(f),first=try await f.peerSession.reviewMembershipUpdate(page),second=try await f.peerSession.reviewMembershipUpdate(page),saved=storage.values
        XCTAssertNotEqual(first,second);try await f.peerSession.stop();await refused(f.peerSession,first)
        let operation=try await change(f.peerSession,second);try operation.close();XCTAssertTrue(storage.values==saved)
    }
    func testDifferentSessionAndReplacementSessionOnSameStoreRefuseOldReview()async throws {
        let a=try await fixture(),b=try await fixture(),page=try await page(a),review=try await a.peerSession.reviewMembershipUpdate(page)
        try await a.peerSession.stop();try await b.peerSession.stop();await refused(b.peerSession,review)
        let owner=try pair(a.peerStore),replacement=try owner.prepareSavedSession();sessions.append(replacement)
        let current=try await replacement.reviewMembershipUpdate(page);try await replacement.stop();await refused(replacement,review)
        let operation=try await change(replacement,current);try operation.close()
    }
    func testBusyCloseKeepsOriginalPairingLeaseUntilExactRetry()async throws {
        let f=try await fixture(),account=try pairingID(f.peerStore),review=try await f.peerSession.reviewMembershipUpdate(page(f))
        try await f.peerSession.stop();let operation=try await change(f.peerSession,review);XCTAssertNil(try operation.apply())
        var statement:OpaquePointer?=try f.peerStore.withMembershipDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        XCTAssertThrowsError(try operation.close());XCTAssertFalse(f.peerStore.isClosed)
        XCTAssertThrowsError(try SyncCredentialExclusiveLease(id:account,stateRoot:environment.stateRoot))
        sqlite3_finalize(statement);statement=nil;try operation.close();XCTAssertTrue(f.peerStore.isClosed)
        let lease=try SyncCredentialExclusiveLease(id:account,stateRoot:environment.stateRoot);lease.close()
    }
    func testAlreadyAppliedForeignAndMalformedPagesDoNotChangeAuthority()async throws {
        let f=try await fixture(),other=try await fixture(),request=try await f.peerSession.membershipUpdateRequest(),trusted=try SyncMembershipUpdateRequest.decode(Data(request.utf8)).certificate
        let already=String(decoding:try SyncMembershipRefresh(base:f.firstCertificate,updates:[trusted]).encoded(),as:UTF8.self),foreign=try await page(other),saved=storage.values
        for invalid in [already,foreign,"untrusted",String(repeating:" ",count:SyncMembershipRefresh.maximumBytes+1)] {
            do {_=try await f.peerSession.reviewMembershipUpdate(invalid);XCTFail("Invalid membership page accepted")}
            catch {}
        }
        XCTAssertTrue(storage.values==saved)
    }
    func testOwnerAndPeerReviewsInvalidateEachOtherAndShareOneTransferReservation()async throws {
        let a=try await fixture(advanceOwner:false),ownerReview=try await a.ownerSession.reviewOwnerAddition(a.request,now:now)
        let peerReview=try await a.ownerSession.reviewMembershipUpdate(futurePage(a));try await a.ownerSession.stop()
        do {_=try await a.ownerSession.ownerChangeAfterStopping(ownerReview);XCTFail("Peer review left owner approval current")}
        catch {}
        let peerChange=try await change(a.ownerSession,peerReview);try peerChange.close()
        let b=try await fixture(advanceOwner:false),oldPeer=try await b.ownerSession.reviewMembershipUpdate(futurePage(b)),current=try await b.ownerSession.reviewOwnerAddition(b.request,now:now)
        try await b.ownerSession.stop();await refused(b.ownerSession,oldPeer)
        let time=now,ownerChange=try await b.ownerSession.ownerChangeAfterStopping(current,clock:{time});changes.append(ownerChange);try ownerChange.close()
    }
}

extension PersonalSyncMembershipUpdateTests {
    private func publicCycle(_ group:[PersonalSyncSession])async throws {
        for session in group {
            try await session.setProcessingEnabled(true)
            let deadline=ContinuousClock.now.advanced(by:.seconds(30))
            while true {
                let state=await session.status()
                if state.phase == .upToDate || state.phase == .waitingForPolicy {break}
                if state.phase == .failed {throw OSwindError.unavailable("Owned public three-device session failed")}
                guard ContinuousClock.now<deadline else {throw OSwindError.unavailable("Owned public three-device cycle did not finish: \(state.phase)")}
                try await Task.sleep(for:.milliseconds(5))
            }
            // These are deliberate public pause/resume cycles, not a claim
            // about automatic scheduling latency, physical devices or power.
            try await session.setProcessingEnabled(false)
        }
    }
    private func hasText(_ text:String,in store:MemoryStore)throws->Bool {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT COUNT(*) FROM memories WHERE text=?");defer {sqlite3_finalize(row)};db.bind(row,1,text)
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(row,0)==1
        }
    }
    func testThreePublicSessionsExchangeAllThirteenKindsThenWriteOfflineAndReconnectWithoutDuplicates()async throws {
        try await threeDeviceTransfer()
    }
    func testOwnedNativeThreePublicSessionsPreserveThirteenKindsAndOriginalAccounts()async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit three-library generated login-Keychain and actual Mac binding fixture")}
        nativeBackend=NativeWriterKeychainFixture()
        try await threeDeviceTransfer()
        if testRun?.totalFailureCount==0 {print("OWNED_NATIVE_PUBLIC_THREE_DEVICE originalAccountIDsPreserved=true originalPrivateFieldsPreserved=true actualMacBinding=true graphKinds=13 offlinePeerWrites=2 reconnect=true")}
    }
    private func threeDeviceTransfer()async throws {
        let f=try await fixture(advanceOwner:false),graph=SyncOutgoingTests();graph.store=f.ownerStore;graph.root=f.ownerStore.root;try graph.seedGraph()
        let originalAccounts=nativeBackend.map {Set($0.accounts)}
        var originalFields=[String:[String:String]]()
        if let backend=nativeBackend {for library in [f.ownerStore,f.peerStore] {let account=try pairingID(library);originalFields[account]=try originalPrivateFields(account,backend:backend)}}
        let expected=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {($0.rawValue,try graph.serviceCount(f.ownerStore,$0.rawValue))});XCTAssertTrue(expected.values.allSatisfy {$0>0})
        let request=try await f.peerSession.membershipUpdateRequest(),ownerReview=try await f.ownerSession.reviewOwnerAddition(f.request,now:now),time=now
        try await f.ownerSession.stop();let addition=try await f.ownerSession.ownerChangeAfterStopping(ownerReview,clock:{time});changes.append(addition)
        let response=try XCTUnwrap(addition.apply(clock:{self.now}));try addition.close();_=try f.joining.acceptResponse(response.response,trustedRootFingerprint:f.fingerprint,now:now)
        let ownerStore=try store(f.ownerStore.root),exporter=try pair(ownerStore),page=try XCTUnwrap(exporter.membershipUpdatePage(for:request));exporter.close()
        let review=try await f.peerSession.reviewMembershipUpdate(page);try await f.peerSession.stop();let update=try await change(f.peerSession,review);XCTAssertNil(try update.apply());try update.close()
        if let backend=nativeBackend,let originalAccounts {
            XCTAssertEqual(Set(backend.accounts),originalAccounts,"Membership update created replacement accounts")
            for account in originalAccounts {_=try backend.read(id:account)}
            for (account,before) in originalFields {XCTAssertTrue(try originalPrivateFields(account,backend:backend)==before,"Original device private fields changed")}
        }
        let peerStore=try store(f.peerStore.root),joiningStore=try XCTUnwrap(stores.first {f.joining.belongs(to:$0)})
        let owner=try pair(ownerStore),peer=try pair(peerStore),ownerSession=try owner.prepareSavedSession(),peerSession=try peer.prepareSavedSession(),joiningSession=try f.joining.prepareSession(sharedFolder:f.folder)
        sessions += [ownerSession,peerSession,joiningSession]
        let enrolledAccounts=nativeBackend.map {Set($0.accounts)}
        if let originalAccounts,let enrolledAccounts {XCTAssertTrue(originalAccounts.isSubset(of:enrolledAccounts));XCTAssertEqual(enrolledAccounts.count,originalAccounts.count+1,"Only the joining Mac's first delivery account should be new")}
        let group=[ownerSession,peerSession,joiningSession],libraries=[ownerStore,peerStore,joiningStore]
        var complete=false
        for _ in 0..<12 {
            try await publicCycle(group)
            complete=try libraries.allSatisfy {library in try SyncCanonicalTable.allCases.allSatisfy {try graph.serviceCount(library,$0.rawValue)==expected[$0.rawValue]}}
            if complete {break}
        }
        XCTAssertTrue(complete,"Public three-device transfer did not preserve the complete thirteen-kind graph")
        guard complete else {return}
        let initialTexts=["Owned new owner write after membership catch-up","Owned new peer write after membership catch-up","Owned joining Mac write after membership catch-up"]
        for (index,library) in libraries.enumerated() {try library.insert(Memory(id:"new-write-\(index)",kind:.note,text:initialTexts[index]))}
        for _ in 0..<8 {try await publicCycle(group);if try libraries.allSatisfy({library in try initialTexts.allSatisfy {try hasText($0,in:library)}}) {break}}
        for library in libraries {for text in initialTexts {XCTAssertTrue(try hasText(text,in:library))}}
        try await ownerSession.stop()
        let offlineTexts=["Owned peer write while group owner is offline","Owned joining Mac write while group owner is offline"]
        try peerStore.insert(Memory(id:"offline-peer",kind:.note,text:offlineTexts[0]));try joiningStore.insert(Memory(id:"offline-joining",kind:.note,text:offlineTexts[1]))
        for _ in 0..<8 {try await publicCycle([peerSession,joiningSession]);if try [peerStore,joiningStore].allSatisfy({library in try offlineTexts.allSatisfy {try hasText($0,in:library)}}) {break}}
        for library in [peerStore,joiningStore] {for text in offlineTexts {XCTAssertTrue(try hasText(text,in:library))}}
        try await peerSession.stop();try await joiningSession.stop();for library in libraries {try library.close()}
        var reopened=[MemoryStore](),resumed=[PersonalSyncSession]()
        for original in libraries {
            let library=try store(original.root),paired=try pair(library),session=try paired.prepareSavedSession();reopened.append(library);resumed.append(session);sessions.append(session)
            XCTAssertEqual(try paired.status().memberNames.count,3)
        }
        for _ in 0..<8 {try await publicCycle(resumed);if try reopened.allSatisfy({library in try offlineTexts.allSatisfy {try hasText($0,in:library)}}) {break}}
        for _ in 0..<3 {try await publicCycle(resumed)}
        for library in reopened {
            for text in initialTexts+offlineTexts {XCTAssertTrue(try hasText(text,in:library),"Missing or duplicated original source after reconnect")}
            for table in SyncCanonicalTable.allCases {
                let original=try XCTUnwrap(expected[table.rawValue]),added=table == .source ? 5:0
                XCTAssertEqual(try graph.serviceCount(library,table.rawValue),original+added,"Changed or duplicated \(table.rawValue) after reconnect/replay")
            }
        }
        if let backend=nativeBackend,let enrolledAccounts {
            XCTAssertEqual(Set(backend.accounts),enrolledAccounts,"Reconnect replaced original accounts")
            for account in enrolledAccounts {_=try backend.read(id:account)}
            for (account,before) in originalFields {XCTAssertTrue(try originalPrivateFields(account,backend:backend)==before,"Reconnect changed original private material")}
        }
        print("OWNED_PUBLIC_THREE_DEVICE graphKinds=13 bidirectionalWrites=3 offlinePeerWrites=2 reconnect=true duplicateReplay=false")
    }
    func testPublicHistoryPagesReachSixtyFourMembersWithoutExportingPrivateAuthority()throws {
        let owner=try pair(store(root.appendingPathComponent("public-page-owner"))),peer=try pair(store(root.appendingPathComponent("public-page-peer")))
        _=try owner.createGroup(deviceName:"Owned bounded history owner",now:now)
        let fingerprint=try XCTUnwrap(owner.status().rootFingerprint),request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned bounded history peer",now:now).request)
        _=try peer.acceptResponse(owner.approve(owner.reviewRequest(request,now:now),now:now),trustedRootFingerprint:fingerprint,now:now)
        var currentRequest=try peer.membershipUpdateRequest(),current=try SyncMembershipUpdateRequest.decode(Data(currentRequest.utf8)).certificate
        for index in 2..<64 {
            let joining=try SyncPendingJoin(name:String(repeating:"M",count:72)+String(index),now:now),text=String(decoding:try joining.request.encoded(),as:UTF8.self)
            _=try owner.approve(owner.reviewRequest(text,now:now),now:now)
        }
        let saved=storage.values;var pages=0
        while let page=try owner.membershipUpdatePage(for:currentRequest) {
            XCTAssertLessThanOrEqual(page.utf8.count,PersonalSyncPairing.maximumMembershipUpdateBytes)
            let proof=try SyncMembershipRefresh.decode(Data(page.utf8));current=try proof.advance(from:current);pages+=1;XCTAssertLessThan(pages,64)
            for key in ["groupSecret","signingPrivate","agreementPrivate","ownerPrivate"] {XCTAssertFalse(page.contains("\""+key+"\""))}
            currentRequest=String(decoding:try SyncMembershipUpdateRequest(certificate:current).encoded(),as:UTF8.self)
        }
        XCTAssertGreaterThan(pages,1);XCTAssertEqual(current.body.members.count,64);XCTAssertTrue(storage.values==saved)
    }
}

extension PersonalSyncMembershipUpdateTests {
    func testOverlappingOlderPageAppliesOnlySuccessorsOfExactCurrentPeer()async throws {
        let f=try await fixture(),originalRequest=try await f.peerSession.membershipUpdateRequest(),exporter=try XCTUnwrap(f.exporting)
        let firstPage=try XCTUnwrap(exporter.membershipUpdatePage(for:originalRequest)),ownerThird=try exporter.prepareSavedSession();sessions.append(ownerThird)
        let fourth=try pair(store(f.folder.deletingLastPathComponent().appendingPathComponent("fourth"))),fourthRequest=try XCTUnwrap(fourth.requestJoin(deviceName:"Owned fourth Mac",now:now).request)
        let ownerReview=try await ownerThird.reviewOwnerAddition(fourthRequest,now:now),time=now
        try await ownerThird.stop();let adding=try await ownerThird.ownerChangeAfterStopping(ownerReview,clock:{time});changes.append(adding)
        let response=try XCTUnwrap(adding.apply(clock:{self.now}));try adding.close();_=try fourth.acceptResponse(response.response,trustedRootFingerprint:f.fingerprint,now:now)
        let latestOwner=try pair(store(f.ownerStore.root)),overlap=try XCTUnwrap(latestOwner.membershipUpdatePage(for:originalRequest)),wire=try SyncMembershipRefresh.decode(Data(overlap.utf8))
        XCTAssertEqual(wire.base.body.revision,2);XCTAssertEqual(wire.head.body.revision,4)
        let firstReview=try await f.peerSession.reviewMembershipUpdate(firstPage);try await f.peerSession.stop();let first=try await change(f.peerSession,firstReview);XCTAssertNil(try first.apply());try first.close()
        let currentStore=try store(f.peerStore.root),currentPairing=try pair(currentStore),current=try currentPairing.prepareSavedSession();sessions.append(current)
        let reviewed=try await current.reviewMembershipUpdate(overlap)
        XCTAssertEqual(reviewed.currentRevision,3);XCTAssertEqual(reviewed.updatedRevision,4);XCTAssertEqual(reviewed.addedDeviceNames,["Owned fourth Mac"])
        XCTAssertEqual(reviewed.updateFingerprint,SyncProtocolLimits.hex(Data(overlap.utf8)),"The review must describe the supplied page, including its authenticated overlap")
        try await current.stop();let before=storage.values,operation=try await change(current,reviewed)
        XCTAssertTrue(storage.values==before,"Retained draft wrote private intent before apply")
        XCTAssertNil(try operation.apply());try operation.close()
        let fresh=try store(currentStore.root),paired=try pair(fresh);XCTAssertEqual(try paired.status().memberNames.count,4)
        try fresh.insert(Memory(id:"after-overlap",text:"Original peer remains writable after overlapping update"));XCTAssertNotNil(try fresh.get("after-overlap"))
    }
}
