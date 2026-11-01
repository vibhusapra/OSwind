import XCTest
@testable import OSwindCore

final class SyncTurnPublicationProtocolTests:XCTestCase {
    let group="00000000-0000-0000-0000-000000006201",epoch="00000000-0000-0000-0000-000000006202",origin="00000000-0000-0000-0000-000000006203"
    private func identity(_ table:SyncCanonicalTable)throws->SyncObjectIdentity {try .init(table:table,origin:origin,lifetime:UUID().uuidString.lowercased())}
    private func fixture(_ count:Int=1)throws->SyncTurnPublication {
        let turn=try identity(.turn),source=try SyncVersionReference(identity:identity(.source),content:.init(data:Data("Authored exact source".utf8)))
        let owner=try SyncVersionReference(identity:turn,content:.init(data:Data("Authored exact answer".utf8)))
        let children=try (0..<count).map {index in try SyncPortableRecord(identity:identity(.conversationCitation),body:.conversationCitation(.init(owner:turn,ordinal:index,link:.init(source:source,score:1,match:"Owned",passage:nil))))}
        return try .init(group:group,epoch:epoch,owner:owner,citations:children)
    }
    func testPublicationCanonicalBoundedDeclarationRejectsAlteredBytesUnknownFieldsAndHoles()throws {
        let value=try fixture(2),bytes=try value.encoded()
        XCTAssertEqual(try SyncTurnPublication.decode(bytes,expected:value.reference),value)
        XCTAssertThrowsError(try SyncTurnPublication.decode(bytes+Data([32]),expected:value.reference))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]);object["unknown"]="must refuse"
        let extra=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        XCTAssertThrowsError(try SyncTurnPublication.decode(extra,expected:.init(data:extra)))
        XCTAssertThrowsError(try SyncTurnPublication(group:group,epoch:epoch,owner:value.owner,citations:[value.citations[1]]))
        XCTAssertThrowsError(try SyncTurnPublication(group:group,epoch:epoch,owner:value.owner,citations:[value.citations[0],value.citations[0]]))
        let other=try fixture();XCTAssertThrowsError(try SyncTurnPublication(group:group,epoch:epoch,owner:other.owner,citations:value.citations))
        let empty=try fixture(0);XCTAssertEqual(empty.citations.count,0);XCTAssertNotEqual(try empty.reference,try value.reference)
        _=try fixture(60);XCTAssertThrowsError(try fixture(61))
    }
    func testPublicationRevisionPreservesLegacyBytesAndBindsOnlyTurnPuts()throws {
        let value=try fixture(),dot=try SyncDot(replica:origin,counter:1),key=try value.owner.identity.key
        let old=try SyncRevision(key:key,dot:dot,context:.empty,mutation:.put,content:value.owner.content),oldBytes=try old.encoded()
        XCTAssertFalse(String(decoding:oldBytes,as:UTF8.self).contains("publication"));XCTAssertEqual(try SyncRevision.decode(oldBytes),old)
        let current=try SyncRevision(key:key,dot:dot,context:.empty,mutation:.put,content:value.owner.content,publication:value.reference)
        XCTAssertNotEqual(try current.encoded(),oldBytes);XCTAssertEqual(try SyncRevision.decode(current.encoded()),current)
        XCTAssertThrowsError(try SyncRevision(key:key,dot:dot,context:.empty,mutation:.delete,publication:value.reference))
        XCTAssertThrowsError(try SyncRevision(key:identity(.source).key,dot:dot,context:.empty,mutation:.put,content:value.owner.content,publication:value.reference))
        XCTAssertThrowsError(try SyncRevision(key:key,dot:dot,context:.empty,mutation:.put,content:value.owner.content,publication:.init(sha256:String(repeating:"a",count:64),bytes:SyncTurnPublication.maximumBytes+1)))
        // Canonical old decoders reencode only their known keys. This local
        // projection illustrates that guard; actual prior binary qualification
        // is a separate acceptance gate, not inferred from this assertion.
        var stripped=try XCTUnwrap(JSONSerialization.jsonObject(with:current.encoded()) as? [String:Any]);stripped.removeValue(forKey:"publication")
        XCTAssertNotEqual(try JSONSerialization.data(withJSONObject:stripped,options:[.sortedKeys,.withoutEscapingSlashes]),try current.encoded())
    }
    func testEncryptedFolderRequiresAndAuthenticatesPublicationBeforeRevision()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-publication-protocol-"+UUID().uuidString),secret=SyncGroupSecret(),value=try fixture(0)
        let folder=try SyncObjectFolder.create(at:root,secret:secret,group:group,epoch:epoch);defer {folder.close();try? FileManager.default.removeItem(at:root)}
        let answer=Data("Authored exact answer".utf8),revision=try SyncRevision(key:value.owner.identity.key,dot:.init(replica:origin,counter:1),context:.empty,mutation:.put,content:value.owner.content,publication:value.reference)
        try folder.publishContent(answer,reference:value.owner.content)
        XCTAssertThrowsError(try folder.publishRevision(revision));XCTAssertNil(try folder.revision(replica:origin,sequence:1))
        try folder.publishContent(value.encoded(),reference:value.reference);try folder.publishRevision(revision)
        XCTAssertEqual(try folder.revision(replica:origin,sequence:1),revision)
        folder.close()
        let reopened=try SyncObjectFolder.open(at:root,secret:secret,group:group,epoch:epoch);defer {reopened.close()}
        XCTAssertEqual(try reopened.content(value.reference),try value.encoded());XCTAssertEqual(try reopened.revision(replica:origin,sequence:1),revision)
        let enumerator=try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]))
        while let file=enumerator.nextObject() as? URL {if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true {let bytes=try Data(contentsOf:file);XCTAssertNil(bytes.range(of:Data("Authored exact answer".utf8)));XCTAssertNil(bytes.range(of:Data("OSwind.sync.turn-publication".utf8)))}}
        XCTAssertThrowsError(try SyncObjectFolder.open(at:root,secret:SyncGroupSecret(),group:group,epoch:epoch))
    }
}
