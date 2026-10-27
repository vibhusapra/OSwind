import XCTest
import Foundation
import CSQLite
@testable import OSwindCore

final class LimitlessImportTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-limitless-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store?.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func record(_ id:String="owned-release",text:String="Maya owns the Aurora release")->[String:Any] {
        ["id":id,"title":"Release review","markdown":text,"startTime":"2024-11-03T01:20:00-04:00","endTime":"2024-11-03T01:40:00-05:00","isStarred":true,"updatedAt":"2024-11-04T12:00:00.123456Z","contents":[["type":"heading1","content":"Release review","children":[["type":"future-node","content":"Robin confirmed Friday","speakerName":"Robin","speakerIdentifier":"user","startTime":"2024-11-03T01:21:00-04:00","endTime":"2024-11-03T01:21:08-04:00","startOffsetMs":60000,"endOffsetMs":68000,"children":[]]]]]]
    }
    func batch(_ records:[[String:Any]],cursor:Any=NSNull())throws->Data {try JSONSerialization.data(withJSONObject:["data":["lifelogs":records],"meta":["lifelogs":["count":records.count,"nextCursor":cursor]]],options:[.sortedKeys])}
    func testFrozenIdentityDSTAndStructuredContentAreSearchableWithoutFabricatedMedia()throws {
        let report=try store.importLimitlessAPI(data:batch([record()])),id=try XCTUnwrap(report.sourceIDs.first)
        XCTAssertEqual(id,"limitless:7e0683806488c62f8e8883807156e149020fec6357e29c8644e3f5ec3155a54f")
        XCTAssertEqual(report.requested,1);XCTAssertEqual(report.imported,1);XCTAssertFalse(report.hasMorePages)
        let source=try XCTUnwrap(store.get(id));XCTAssertEqual(source.kind,.note);XCTAssertTrue(source.favorite);XCTAssertEqual(source.tags,["import:limitless"])
        XCTAssertEqual(try ISOTime.string(source.timestamp),"2024-11-03T05:20:00Z");XCTAssertEqual(try XCTUnwrap(source.endTimestamp).timeIntervalSince(source.timestamp),4800)
        for text in ["Maya owns", "[future-node]", "Robin confirmed Friday", "speakerName: Robin", "speakerIdentifier: user", "startOffsetMs: 60000", "2024-11-04T12:00:00.123456Z"] {XCTAssertTrue(source.text.contains(text),text)}
        XCTAssertNil(source.url);XCTAssertNil(source.transcript);XCTAssertNil(source.audioPath);XCTAssertNil(source.imagePath);XCTAssertNil(source.videoPath)
        XCTAssertEqual(try store.search(SearchFilter(query:"Friday"),mode:.keyword).map(\.id),[id])
    }
    func testSingleResponseNullMarkdownAndPaginationAreExplicit()throws {
        var one=record();one["markdown"]=NSNull()
        let single=try JSONSerialization.data(withJSONObject:["data":["lifelog":one]])
        let result=try store.importLimitlessAPI(data:single);XCTAssertEqual(result.imported,1)
        XCTAssertTrue(try XCTUnwrap(store.get(result.sourceIDs[0])).text.contains("Markdown: null"))
        XCTAssertTrue(try store.importLimitlessAPI(data:batch([record()],cursor:"next-owned-page")).hasMorePages)
        XCTAssertEqual(try store.importLimitlessAPI(data:batch([])).imported,0)
        let bad=Data(#"{"data":{"lifelogs":[]},"meta":{"lifelogs":{"count":1}}}"#.utf8)
        XCTAssertThrowsError(try store.importLimitlessAPI(data:bad))
    }
    func testExactUnicodeIDsAndTextSurviveIncludingBOMAndCombiningMarks()throws {
        let values=["\u{feff}id","id","é","e\u{301}"]
        let result=try store.importLimitlessAPI(data:batch(values.map {record($0,text:"\u{feff}\u{301}Exact \"quoted\" \\ slash\nline")}))
        XCTAssertEqual(Set(result.sourceIDs).count,4)
        XCTAssertEqual(result.sourceIDs,["limitless:8d82b45e1d8c20075cb9df3b52f369028d81137ad5f85f1a5011c2aa088a2f16","limitless:a56145270ce6b3bebd1dd012b73948677dd618d496488bc608a3cb43ce3547dd","limitless:4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c","limitless:bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6"])
        for id in result.sourceIDs {XCTAssertTrue(try XCTUnwrap(store.get(id)).text.utf8.containsSubsequence(Array("\u{feff}\u{301}Exact \"quoted\" \\ slash\nline".utf8)))}
        var escaped=String(decoding:try batch([record("\u{feff}escaped")]),as:UTF8.self);escaped=escaped.replacingOccurrences(of:"\u{feff}",with:"\\uFEFF")
        XCTAssertEqual(try store.importLimitlessAPI(data:Data(escaped.utf8)).sourceIDs,[try LimitlessImport.sourceID("\u{feff}escaped")])
    }
    func testRetryPreservesUserCurationAndInvalidatesChangedEntityEvidence()throws {
        let result=try store.importLimitlessAPI(data:batch([record()])),id=result.sourceIDs[0],source=try XCTUnwrap(store.get(id)),plan=try store.entityIndexPlan()
        let range=try XCTUnwrap(source.text.range(of:"Maya")),ns=NSRange(range,in:source.text)
        try store.saveEntityExtraction(memory:source,plan:plan,result:.init(candidates:[.init(kind:.person,name:"Maya",start:ns.location,length:ns.length)]))
        XCTAssertEqual(try store.entities().count,1)
        try store.setFavorite(id,value:false);try store.setTags(id,tags:["reviewed"])
        _=try store.importLimitlessAPI(data:batch([record(text:"Cedar changed owner")]))
        let updated=try XCTUnwrap(store.get(id));XCTAssertFalse(updated.favorite);XCTAssertEqual(Set(updated.tags),Set(["reviewed","import:limitless"]))
        XCTAssertTrue(updated.text.contains("Cedar changed owner"));XCTAssertTrue(try store.entities().isEmpty);XCTAssertEqual(try store.stats().count,1)
    }
    func testPrivacyAppliesToAllRenderedTextAndExcludedRecordsAreCounted()throws {
        var privateRecord=record("excluded");privateRecord["title"]="Private browsing review"
        var secret=record("allowed",text:"password=owned-fixture-value");secret["contents"]=[["type":"paragraph","content":"api_key=owned-fixture-value","speakerName":"secret=owned-fixture-value"]]
        let result=try store.importLimitlessAPI(data:batch([privateRecord,secret]));XCTAssertEqual(result.excluded,1);XCTAssertEqual(result.imported,1)
        let text=try XCTUnwrap(store.get(result.sourceIDs[1])).text;XCTAssertFalse(text.contains("owned-fixture-value"));XCTAssertTrue(text.contains("[REDACTED]"))
        var policy=PrivacyPolicy();policy.excludedApps=["ai.limitless.import"]
        XCTAssertEqual(try store.importLimitlessAPI(data:batch([record("another")]),policy:policy).excluded,1)
    }
    func testMalformedFinalRecordAndUnknownFieldsNeverPublishEarlierChanges()throws {
        let first=try store.importLimitlessAPI(data:batch([record()])),id=first.sourceIDs[0]
        var bad=record("last");bad["endTime"]="2020-01-01T00:00:00Z"
        XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([record(text:"must not publish"),bad])))
        for key in ["audioPath","unknownFutureField"] {var unknown=record();unknown[key]="refuse rather than discard";XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([unknown])))}
        var node=record();node["contents"]=[["type":"paragraph","content":"owned","unknown":"must refuse"]];XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([node])))
        XCTAssertTrue(try XCTUnwrap(store.get(id)).text.contains("Maya owns"));XCTAssertEqual(try store.stats().count,1)
    }
    func testDuplicateEscapedKeysTrailingDataAndMalformedTokensRefuse()throws {
        let original=String(decoding:try batch([record()]),as:UTF8.self)
        for malformed in [original.replacingOccurrences(of:"\"id\":",with:"\"id\":\"duplicate\",\"\\u0069d\":"),original+" true","[",original.replacingOccurrences(of:"\"isStarred\":true",with:"\"isStarred\":1"),original.replacingOccurrences(of:"\"count\":1",with:"\"count\":01")] {XCTAssertThrowsError(try store.importLimitlessAPI(data:Data(malformed.utf8)))}
        XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([record(),record()])))
        XCTAssertEqual(try store.stats().count,0)
    }
    func testUTF8FileBOMIsSeparateFromStringBOMAndMalformedUnicodeRefuses()throws {
        var data=Data([0xef,0xbb,0xbf]);data.append(try batch([record("\u{feff}id")]))
        XCTAssertEqual(try store.importLimitlessAPI(data:data).sourceIDs,[try LimitlessImport.sourceID("\u{feff}id")])
        let original=String(decoding:try batch([record()]),as:UTF8.self)
        for replacement in [#""\uD800""#,#""\uDC00""#] {
            let malformed=original.replacingOccurrences(of:"\"owned-release\"",with:replacement)
            XCTAssertThrowsError(try store.importLimitlessAPI(data:Data(malformed.utf8)))
        }
        let malformed=Data([123,34,100,97,116,97,34,58,34,0xff,34,125]);XCTAssertThrowsError(try store.importLimitlessAPI(data:malformed))
    }
    func testTimezonesReversedOffsetsAndNULRefuseWithoutDateGuessing()throws {
        for value in ["2024-11-03T01:20:00","2024-02-30T00:00:00Z","not-a-date"] {var bad=record();bad["startTime"]=value;XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([bad])))}
        var bad=record();bad["contents"]=[["type":"paragraph","content":"owned","startOffsetMs":8,"endOffsetMs":7]];XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([bad])))
        bad=record();bad["markdown"]="owned\u{0}invalid";XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([bad])))
        XCTAssertEqual(try store.stats().count,0)
    }
    func testWholeTransactionRollsBackIfLaterIDBelongsToIncompatibleSource()throws {
        let id=try LimitlessImport.sourceID("last");try store.insert(Memory(id:id,kind:.audio,text:"Keep owned original"))
        XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([record(),record("last")])))
        XCTAssertNil(try store.get(LimitlessImport.sourceID("owned-release")));XCTAssertEqual(try store.get(id)?.text,"Keep owned original")
    }
    func testBoundsAndUnsupportedShapesRefuse()throws {
        XCTAssertThrowsError(try store.importLimitlessAPI(data:Data(repeating:32,count:LimitlessImport.maximumBytes+1)))
        XCTAssertThrowsError(try store.importLimitlessAPI(data:batch((0..<1001).map {record(String($0))})))
        for raw in [#"{"data":{"lifelogs":[],"lifelog":{}}}"#,#"{"data":{"lifelogs":[]},"unexpected":true}"#,#"{"data":{"lifelogs":[]},"meta":{"lifelogs":{"count":0,"nextCursor":""}}}"#] {XCTAssertThrowsError(try store.importLimitlessAPI(data:Data(raw.utf8)))}
        var deep:[String:Any]=["type":"paragraph","content":"owned"]
        for _ in 0..<20 {deep=["type":"paragraph","content":"owned","children":[deep]]}
        var bad=record();bad["contents"]=[deep];XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([bad])))
        bad=record();bad["contents"]=[];bad["markdown"]=NSNull();XCTAssertThrowsError(try store.importLimitlessAPI(data:batch([bad])))
        XCTAssertEqual(try store.stats().count,0)
    }
    func testBoundedFileReadRefusesSymlinkAndExportReopenPreservesNotes()throws {
        let input=root.appendingPathComponent("owned.json"),link=root.appendingPathComponent("link.json");try batch([record()]).write(to:input)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:input);XCTAssertThrowsError(try store.importLimitlessAPI(from:link))
        let result=try store.importLimitlessAPI(from:input),before=try XCTUnwrap(store.get(result.sourceIDs[0])),output=root.appendingPathComponent("export.json");try store.exportJSON(to:output)
        try store.close();store=try MemoryStore(root:root);XCTAssertEqual(try store.get(before.id),before)
        let other=try MemoryStore(root:root.appendingPathComponent("other"));defer {try? other.close()};XCTAssertEqual(try other.importJSON(from:output),1);XCTAssertEqual(try other.get(before.id),before)
    }
    func testAlreadyCancelledAndClosedStoreRefuse()async throws {
        let data=try batch([record()]),store=self.store!
        let worker=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try store.importLimitlessAPI(data:data)}
        do {_=try await worker.value;XCTFail("Already cancelled import ran")}catch is CancellationError {} catch {throw error}
        XCTAssertEqual(try store.stats().count,0);try store.close();XCTAssertThrowsError(try store.importLimitlessAPI(data:data))
    }
    func testCancellationDuringFirstWriteRollsBackWholePageAndStoreCanRetry()async throws {
        let data=try batch([record("one"),record("two")]),store=self.store!
        try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,_,_,sql in
            if let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO memories(") {withUnsafeCurrentTask {$0?.cancel()}};return 0
        },nil)}
        let worker=Task.detached {try store.importLimitlessAPI(data:data)}
        do {_=try await worker.value;XCTFail("Cancelled page committed")}catch is CancellationError {} catch {throw error}
        try store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        XCTAssertEqual(try store.stats().count,0);XCTAssertEqual(try store.importLimitlessAPI(data:data).imported,2)
    }
}

private extension Collection where Element==UInt8 {
    func containsSubsequence(_ needle:[UInt8])->Bool {let bytes=Array(self);return bytes.indices.contains {start in start+needle.count<=bytes.count && bytes[start..<start+needle.count].elementsEqual(needle)}}
}
