import XCTest
import CSQLite
@testable import OSwindCore

final class SyncSignedFolderTests:XCTestCase {
    var root:URL!,a:SyncJoinedGroup!,b:SyncJoinedGroup!,left:SyncObjectFolder!,right:SyncObjectFolder!,secret:SyncGroupSecret!
    var group:String {a.certificate.body.group};var epoch:String {a.certificate.body.epoch}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-signed-folder-"+UUID().uuidString);try Paths.ensure(root)
        let owner=try SyncPendingJoin(name:"Owner"),join=try SyncPendingJoin(name:"Peer"),authority=try SyncGroupAuthority(owner:owner.request).admitting(join.request)
        a=try owner.accept(authority.response(to:owner.request),expectedRootFingerprint:authority.fingerprint)
        b=try join.accept(authority.response(to:join.request),expectedRootFingerprint:authority.fingerprint)
        // Known group AEAD material lets these adversarial fixtures forge valid
        // group encryption independently of either device's signing key.
        secret=SyncGroupSecret()
        left=try .create(at:root.appendingPathComponent("space"),secret:secret,group:group,epoch:epoch,authority:a.packetAuthority())
        right=try .open(at:left.root,secret:secret,group:group,epoch:epoch,authority:b.packetAuthority())
    }
    override func tearDownWithError()throws {left?.close();right?.close();a=nil;b=nil;try FileManager.default.removeItem(at:root)}
    func revision(_ replica:String,counter:Int64=1,body:Data,context:SyncClock = .empty)throws->SyncRevision {
        try .init(key:.make(kind:.source,identity:Data("owned signed source".utf8)),dot:.init(replica:replica,counter:counter),context:context,mutation:.put,content:.init(data:body))
    }
    func publish(_ value:SyncRevision,bytes:Data,in folder:SyncObjectFolder)throws {
        try folder.publishContent(bytes,reference:XCTUnwrap(value.content));try folder.publishRevision(value)
    }
    func operationDescriptor(_ replica:String,_ counter:Int64)->Data {Data("OSwind.sync.operation.v1\0\(replica)\0\(counter)".utf8)}
    func forged(_ plaintext:Data,purpose:SyncObjectPurpose,descriptor:Data,head:Bool=false)throws->URL {
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:purpose),sealed=try cipher.seal(plaintext,descriptor:descriptor)
        XCTAssertEqual(try cipher.open(sealed.bytes,expectedToken:sealed.token,descriptor:descriptor),plaintext,"This must be a valid group-authenticated object")
        let path=head ? "heads/"+sealed.token:"objects/\(sealed.token.prefix(2))/\(sealed.token)"
        let url=left.root.appendingPathComponent(path);try Paths.ensure(url.deletingLastPathComponent());try sealed.bytes.write(to:url);return url
    }
    func testSignedSpaceHasOnlyV3MarkerAndCannotAdoptLegacySpace()throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath:left.root.appendingPathComponent("space-v3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:left.root.appendingPathComponent("space-v2").path))
        XCTAssertThrowsError(try SyncObjectFolder.open(at:left.root,secret:secret,group:group,epoch:epoch))
        let old=try SyncObjectFolder.create(at:root.appendingPathComponent("legacy"),secret:secret,group:group,epoch:epoch);defer {old.close()}
        XCTAssertThrowsError(try SyncObjectFolder.open(at:old.root,secret:secret,group:group,epoch:epoch,authority:a.packetAuthority()))
        try FileManager.default.copyItem(at:old.root.appendingPathComponent("space-v2"),to:left.root.appendingPathComponent("space-v2"))
        XCTAssertThrowsError(try SyncObjectFolder.open(at:left.root,secret:secret,group:group,epoch:epoch,authority:a.packetAuthority()))
        XCTAssertThrowsError(try SyncObjectFolder.create(at:root.appendingPathComponent("wrong-group"),secret:secret,group:UUID().uuidString.lowercased(),epoch:epoch,authority:a.packetAuthority()))
    }
    func testSignedOperationAndFullChunksRoundTripWithoutPlaintextHeaders()throws {
        let body=Data(repeating:43,count:SyncCipherContext.maximumPlaintextBytes+123),value=try revision(a.replica,body:body)
        try publish(value,bytes:body,in:left);try left.publishRevision(value)
        XCTAssertEqual(try right.revision(replica:a.replica,sequence:1),value)
        XCTAssertEqual(try right.content(XCTUnwrap(value.content)),body)
        let files=try XCTUnwrap(FileManager.default.enumerator(at:left.root,includingPropertiesForKeys:[.isRegularFileKey]))
        for case let file as URL in files where file.lastPathComponent.count==64 {
            let bytes=try Data(contentsOf:file)
            XCTAssertNil(bytes.range(of:Data(a.replica.utf8)));XCTAssertNil(bytes.range(of:Data("device-packet".utf8)))
        }
    }
    func testMemberCannotPublishAnotherDevicesOperationsHeadsControlsOrProofs()throws {
        let bytes=Data("first".utf8),first=try revision(a.replica,body:bytes)
        try publish(first,bytes:bytes,in:left)
        XCTAssertThrowsError(try right.publishRevision(first),"Idempotence cannot bypass writer identity")
        let head=try SyncServiceHead(group:group,epoch:epoch,replica:a.replica,through:1,collectionCounter:0)
        try left.publishServiceHead(head);XCTAssertThrowsError(try right.publishServiceHead(head))
        let control=try SyncCollectionControl(group:group,epoch:epoch,creator:a.replica,counter:1,era:.init([a.replica:1]))
        try left.publishCollectionControl(control);XCTAssertThrowsError(try right.publishCollectionControl(control))
        XCTAssertThrowsError(try right.publishErasedRevision(first,control:control))
        let nextBytes=Data("next".utf8),next=try revision(a.replica,counter:2,body:nextBytes,context:.init([a.replica:1]))
        try publish(next,bytes:nextBytes,in:left)
        XCTAssertThrowsError(try right.publishSupersededRevision(first,successor:next))
        try left.publishSupersededRevision(first,successor:next)
        XCTAssertEqual(try right.supersedingRevision(for:first),next)
    }
    func testGroupKeyAloneCannotForgeOperationControlHeadOrSupersession()throws {
        let bytes=Data("owned source".utf8),value=try revision(a.replica,body:bytes)
        _=try forged(value.encoded(),purpose:.operation,descriptor:operationDescriptor(a.replica,1))
        XCTAssertThrowsError(try right.revision(replica:a.replica,sequence:1))
        let control=try SyncCollectionControl(group:group,epoch:epoch,creator:a.replica,counter:1,era:.init([a.replica:1]))
        _=try forged(control.encoded(),purpose:.collectionControl,descriptor:SyncCollectionControl.descriptor(creator:a.replica,counter:1))
        XCTAssertThrowsError(try right.collectionControl(creator:a.replica,counter:1))
        let head=try SyncServiceHead(group:group,epoch:epoch,replica:a.replica,through:1,collectionCounter:0)
        _=try forged(head.encoded(),purpose:.checkpoint,descriptor:SyncServiceHead.descriptor(a.replica),head:true)
        XCTAssertThrowsError(try right.serviceHead(replica:a.replica))
        let next=try revision(a.replica,counter:2,body:bytes,context:.init([a.replica:1])),proof=try SyncSupersessionProof(obsolete:value,successor:next)
        _=try forged(proof.encoded(),purpose:.supersession,descriptor:SyncSupersessionProof.descriptor(value.dot))
        XCTAssertThrowsError(try right.supersedingRevision(for:value))
    }
    func testEnsuringPeerCollectionControlRequiresItsOriginalSignedObject()throws {
        let control=try SyncCollectionControl(group:group,epoch:epoch,creator:a.replica,counter:1,era:.init([a.replica:1]))
        XCTAssertThrowsError(try right.ensureAuthenticatedCollectionControl(control))
        XCTAssertNil(try right.collectionControl(creator:a.replica,counter:1))
        try left.ensureAuthenticatedCollectionControl(control)
        let descriptor=try SyncCollectionControl.descriptor(creator:a.replica,counter:1)
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.collectionControl),token=try cipher.token(for:descriptor)
        let url=left.root.appendingPathComponent("objects/\(token.prefix(2))/\(token)"),original=try Data(contentsOf:url)
        try right.ensureAuthenticatedCollectionControl(control)
        XCTAssertEqual(try Data(contentsOf:url),original,"Reusing a verified peer control cannot rewrite its signature")
        XCTAssertThrowsError(try right.publishCollectionControl(control),"The direct signing API must still refuse impersonation")
        _=try forged(control.encoded(),purpose:.collectionControl,descriptor:descriptor)
        XCTAssertThrowsError(try right.ensureAuthenticatedCollectionControl(control),"Possessing the group key does not authenticate a creator")
    }
    func testCrossDeviceSupersessionRequiresActualSuccessorSignature()throws {
        let firstBytes=Data("first".utf8),first=try revision(a.replica,body:firstBytes)
        let nextBytes=Data("next".utf8),next=try revision(b.replica,body:nextBytes,context:.init([a.replica:1]))
        try publish(first,bytes:firstBytes,in:left);try publish(next,bytes:nextBytes,in:right)
        try left.publishSupersededRevision(first,successor:next)
        XCTAssertEqual(try right.supersedingRevision(for:first),next)
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.operation),token=try cipher.token(for:operationDescriptor(b.replica,1))
        try FileManager.default.removeItem(at:left.root.appendingPathComponent("objects/\(token.prefix(2))/\(token)"))
        XCTAssertNil(try right.supersedingRevision(for:first),"A's embedded copy cannot replace unavailable B authorship")
    }
    func testSameDeviceSupersessionRetainsAuthenticatedEmbeddedFallback()throws {
        let bytes=Data("owned".utf8),first=try revision(a.replica,body:bytes),next=try revision(a.replica,counter:2,body:bytes,context:.init([a.replica:1]))
        try publish(first,bytes:bytes,in:left);try publish(next,bytes:bytes,in:left);try left.publishSupersededRevision(first,successor:next)
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.operation),token=try cipher.token(for:operationDescriptor(a.replica,2))
        try FileManager.default.removeItem(at:left.root.appendingPathComponent("objects/\(token.prefix(2))/\(token)"))
        XCTAssertEqual(try right.supersedingRevision(for:first),next)
    }
    func testDevicePacketBindsEveryAuthorityDimensionAndRejectsTampering()throws {
        let authority=try a.packetAuthority(),receiver=try b.packetAuthority(),descriptor=Data("owned exact slot".utf8),payload=Data("owned packet".utf8)
        let packet=try authority.seal(payload,purpose:.operation,descriptor:descriptor,replica:a.replica)
        XCTAssertEqual(try receiver.open(packet,purpose:.operation,descriptor:descriptor,replica:a.replica),payload)
        XCTAssertThrowsError(try receiver.open(packet,purpose:.checkpoint,descriptor:descriptor,replica:a.replica))
        XCTAssertThrowsError(try receiver.open(packet,purpose:.operation,descriptor:Data("another slot".utf8),replica:a.replica))
        XCTAssertThrowsError(try receiver.open(packet,purpose:.operation,descriptor:descriptor,replica:b.replica))
        XCTAssertThrowsError(try authority.seal(payload,purpose:.operation,descriptor:descriptor,replica:b.replica))
        XCTAssertThrowsError(try authority.seal(payload,purpose:.contentChunk,descriptor:descriptor,replica:a.replica))
        XCTAssertThrowsError(try authority.seal(Data(repeating:0,count:69633),purpose:.operation,descriptor:descriptor,replica:a.replica))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:packet) as? [String:Any]),body=try XCTUnwrap(object["body"] as? [String:Any])
        body["payload"]=Data("changed packet".utf8).base64EncodedString();object["body"]=body
        let tampered=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        XCTAssertThrowsError(try receiver.open(tampered,purpose:.operation,descriptor:descriptor,replica:a.replica))
        XCTAssertThrowsError(try receiver.open(packet+Data([10]),purpose:.operation,descriptor:descriptor,replica:a.replica))
    }
    func testJoinedDevicesRunActualNativeServiceOverSignedTransport()throws {
        let shared=root.appendingPathComponent("joined-transport"),aFolder=try a.createTransport(at:shared),bFolder=try b.openTransport(at:shared)
        defer {aFolder.close();bFolder.close()}
        let first=try MemoryStore(root:root.appendingPathComponent("first")),second=try MemoryStore(root:root.appendingPathComponent("second"))
        defer {try? first.close();try? second.close()}
        let aInbox=try a.createPrivateInbox(at:first.root.appendingPathComponent("images/signed-inbox")),bInbox=try b.createPrivateInbox(at:second.root.appendingPathComponent("images/signed-inbox"))
        defer {aInbox.close();bInbox.close()}
        let sender=try SyncLibraryService.install(library:first,replica:a.replica,group:group,epoch:epoch,peers:[b.replica],transport:aFolder,inbox:aInbox)
        defer {try? sender.stop()}
        let receiver=try SyncLibraryService.install(library:second,replica:b.replica,group:group,epoch:epoch,peers:[a.replica],transport:bFolder,inbox:bInbox)
        defer {try? receiver.stop()}
        try first.insert(Memory(id:"signed-a",kind:.note,text:"Owned signed source from office"))
        try second.insert(Memory(id:"signed-b",kind:.note,text:"Owned signed source from travel"))
        func settle(_ service:SyncLibraryService)throws {
            for _ in 0..<300 {
                switch try service.tick(limit:2) {
                case .preparing,.reviewingPolicy:continue
                case .transferred:return
                default:throw OSwindError.invalid("Signed owned service did not transfer")
                }
            };throw OSwindError.invalid("Signed service exceeded bounded fixture work")
        }
        try settle(sender);try settle(receiver);try settle(sender);try settle(receiver)
        let firstHits=try first.search(.init(query:"Owned signed source")),secondHits=try second.search(.init(query:"Owned signed source"))
        XCTAssertEqual(Set(firstHits.map {$0.memory.text}),Set(["Owned signed source from office","Owned signed source from travel"]))
        XCTAssertEqual(Set(secondHits.map {$0.memory.text}),Set(firstHits.map {$0.memory.text}))
        XCTAssertEqual(try sender.cache.journal.cursor(for:b.replica),1);XCTAssertEqual(try receiver.cache.journal.cursor(for:a.replica),1)
        XCTAssertEqual(try aFolder.serviceHead(replica:b.replica)?.through,1);XCTAssertEqual(try bFolder.serviceHead(replica:a.replica)?.through,1)
        XCTAssertEqual(try sender.cache.journal.outbox().count,1);XCTAssertEqual(try receiver.cache.journal.outbox().count,1,"A received record must not become an echo operation")
    }
}
