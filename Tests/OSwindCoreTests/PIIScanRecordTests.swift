import XCTest
import CSQLite
@testable import OSwindCore

final class PIIScanRecordTests:XCTestCase {
    var parent:URL!,root:URL!,store:MemoryStore!
    override func setUpWithError()throws {
        parent=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-pii-record-"+UUID().uuidString)
        root=parent.appendingPathComponent("library");store=try MemoryStore(root:root)
    }
    override func tearDownWithError()throws {try store?.close();store=nil;try? FileManager.default.removeItem(at:parent)}
    func note(_ id:String="owned",text:String="password=OwnedRecordSecret") -> Memory {Memory(id:id,timestamp:Date(timeIntervalSince1970:1767225600),kind:.note,app:"Fixture",bundleID:"org.example.fixture",title:"Owned fixture",text:text)}
    @discardableResult func scan(_ memories:[Memory])async throws->JSONImportResult {
        let backend=PIIInspectorTests.Backend(),scanner=PIIImportScanner(inspector:PIIInspector(loader:{backend}))
        do {let result=try await store.importDecodedMemoriesWithPII(memories,embedder:nil,policy:.init(),scanner:scanner);await scanner.shutdown();return result}
        catch {await scanner.shutdown();throw error}
    }
    func sql(_ text:String)throws {try store.withRoutineDatabase {try $0.execute(text)}}
    func recordCount()throws->Int {try store.withRoutineDatabase {db in let row=try db.statement("SELECT COUNT(*) FROM pii_scan_records");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return Int(sqlite3_column_int64(row,0))}}
    func mutateReceipt(_ change:(inout [String:Any])->Void)throws {
        try store.withRoutineDatabase {db in
            let read=try db.statement("SELECT receipt FROM pii_scan_records WHERE memory_id='owned'");defer {sqlite3_finalize(read)};XCTAssertEqual(sqlite3_step(read),SQLITE_ROW)
            let data=Data(bytes:try XCTUnwrap(sqlite3_column_blob(read,0)),count:Int(sqlite3_column_bytes(read,0)))
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);change(&object)
            let encoded=try JSONSerialization.data(withJSONObject:object),write=try db.statement("UPDATE pii_scan_records SET receipt=? WHERE memory_id='owned'");defer {sqlite3_finalize(write)}
            _=encoded.withUnsafeBytes {sqlite3_bind_blob(write,1,$0.baseAddress,Int32(encoded.count),db.transient)};try db.done(write)
        }
    }
    func testFreshAndMigratedLibrariesDoNotInventChecks()throws {
        try store.insert(note());XCTAssertEqual(try store.piiScanStatus("owned").state,.notRecorded)
        let before=try store.get("owned");try sql("DROP TRIGGER pii_scan_source_changed;DROP TABLE pii_scan_records;PRAGMA user_version=22")
        try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try store.get("owned"),before);XCTAssertEqual(try store.piiScanStatus("owned").state,.notRecorded);XCTAssertEqual(try recordCount(),0)
    }
    func testModelCheckPersistsOnlyBoundAdmittedOutputAcrossReopen()async throws {
        let start=Date(),result=try await scan([note()]),memory=try XCTUnwrap(store.get("owned")),status=try store.piiScanStatus("owned")
        XCTAssertEqual(status.state,.recorded);XCTAssertFalse(status.privacyAcceptance)
        let record=try XCTUnwrap(status.record);XCTAssertEqual(record.modelID,PIIInspector.expectedModelID(.cpu));XCTAssertEqual(record.compute,.cpu);XCTAssertEqual(record.threshold,0.5)
        XCTAssertTrue(record.redacted);XCTAssertEqual(record.fields,result.learnedPrivacy?.fields);XCTAssertEqual(record.windows,result.learnedPrivacy?.windows)
        XCTAssertGreaterThanOrEqual(record.checkedAt,start);XCTAssertEqual(record.contentSHA256,try PIIScanContent.digest(memory));XCTAssertNotEqual(record.contentSHA256,try PIIScanContent.digest(note()))
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(record),as:UTF8.self).contains("OwnedRecordSecret"))
        try store.close();store=try MemoryStore(root:root);XCTAssertEqual(try store.piiScanStatus("owned"),status)
    }
    func testFavoritePreservesCheckAndTagsInvalidateWithoutResurrection()async throws {
        try await scan([note()]);let original=try store.piiScanStatus("owned")
        try store.setFavorite("owned",value:true);XCTAssertEqual(try store.piiScanStatus("owned"),original)
        try store.setTags("owned",tags:["new metadata"]);XCTAssertEqual(try store.piiScanStatus("owned").state,.changed)
        XCTAssertEqual(try store.piiScanStatus("owned").record,original.record)
        try store.setTags("owned",tags:[]);try store.setFavorite("owned",value:false)
        XCTAssertEqual(try store.piiScanStatus("owned").state,.changed,"Returning to old content cannot revive an invalidated check")
        try await scan([try XCTUnwrap(store.get("owned"))]);XCTAssertEqual(try store.piiScanStatus("owned").state,.recorded)
    }
    func testPlainReplacementEvenWithSameContentInvalidatesRecordedCheck()async throws {
        try await scan([note()]);let saved=try XCTUnwrap(store.get("owned"))
        _ = try store.importJSONDetailed(data:JSONEncoder().encode([saved]))
        XCTAssertEqual(try store.piiScanStatus("owned").state,.changed)
        try store.setFavorite("owned",value:true);XCTAssertEqual(try store.piiScanStatus("owned").state,.changed)
    }
    func testEmbeddingColumnUpdatesDoNotTurnTextCheckIntoNoCheck()async throws {
        try await scan([note()]);let old=try store.piiScanStatus("owned")
        try sql("UPDATE memories SET embedding=X'00000000',embedding_model='owned-index' WHERE id='owned'")
        XCTAssertEqual(try store.piiScanStatus("owned"),old)
    }
    func testDirectWriterAndMissingTriggerCannotProduceMatchingChangedContent()async throws {
        try await scan([note()]);let old=try store.piiScanStatus("owned")
        try sql("DROP TRIGGER pii_scan_source_changed")
        var memory=try XCTUnwrap(store.get("owned"));memory.title="Replaced without normal writer"
        try store.withRoutineDatabase {db in let row=try db.statement("UPDATE memories SET payload=? WHERE id='owned'");defer {sqlite3_finalize(row)};try db.bind(row,1,json:memory);try db.done(row)}
        XCTAssertEqual(try store.piiScanStatus("owned").state,.changed);XCTAssertEqual(try store.piiScanStatus("owned").record,old.record)
    }
    func testSourceColumnOnlyChangeInvalidatesEvenIfPayloadUnchanged()async throws {
        try await scan([note()]);try sql("UPDATE memories SET title='other SQL title' WHERE id='owned'")
        XCTAssertEqual(try store.piiScanStatus("owned").state,.changed)
    }
    func testSelectedOldSourceAndIncompletePreviewCannotClaimCurrentRecord()async throws {
        let old=note();try await scan([old]);XCTAssertEqual(try store.piiScanStatus("owned",matching:old).state,.changed)
        var saved=try XCTUnwrap(store.get("owned"));XCTAssertEqual(try store.piiScanStatus("owned",matching:saved).state,.recorded)
        saved.searchPreview=MemorySearchPreview(memory:saved,transcript:.init(text:saved.text,duration:1,segments:[],model:"fixture"))
        XCTAssertThrowsError(try store.piiScanStatus("owned",matching:saved));XCTAssertThrowsError(try store.piiScanStatus("other",matching:old))
    }
    func testUnknownAndMalformedRecordsNeverBecomeRecorded()async throws {
        for change:([String:Any])->[String:Any] in [
            {var x=$0;x["version"]=99;return x}, {var x=$0;x["coverage"]="foreign";return x},
            {var x=$0;x["threshold"]=0;return x}, {var x=$0;x["fields"]=0;return x},
            {var x=$0;x["windows"]=999;return x}, {var x=$0;x["framedTokens"]=0;return x},
            {var x=$0;x["contentSHA256"]=String(repeating:"a",count:64);return x}
        ] {
            try await scan([note()]);try mutateReceipt {$0=change($0)}
            XCTAssertEqual(try store.piiScanStatus("owned").state,.unavailable)
        }
    }
    func testArbitraryAndForgedJSONCannotMintLocalChecks()async throws {
        try await scan([note()]);let record=try XCTUnwrap(store.piiScanStatus("owned").record)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(note("forged"))) as? [String:Any])
        let forged=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record))
        object["piiScanRecord"]=forged;object["privacyScan"]=forged;object["privacyAcceptance"]=true
        _ = try store.importJSONDetailed(data:JSONSerialization.data(withJSONObject:[object]))
        XCTAssertEqual(try store.piiScanStatus("forged").state,.notRecorded);XCTAssertEqual(try recordCount(),1)
        let exported=parent.appendingPathComponent("export.json");try store.exportJSON(to:exported)
        let other=try MemoryStore(root:parent.appendingPathComponent("other"));defer {try? other.close()}
        _ = try other.importJSONDetailed(from:exported);XCTAssertEqual(try other.piiScanStatus("owned").state,.notRecorded)
    }
    func testReceiptFailureRollsBackAllSourcesAndRestoresOldReceipt()async throws {
        try await scan([note()]);let memory=try store.get("owned"),status=try store.piiScanStatus("owned")
        try sql("CREATE TRIGGER owned_receipt_refusal BEFORE INSERT ON pii_scan_records WHEN NEW.memory_id='two' BEGIN SELECT RAISE(ABORT,'owned failure'); END")
        do {try await scan([note(text:"Replacement"),note("two")]);XCTFail("Receipt error partially committed")} catch {}
        XCTAssertEqual(try store.get("owned"),memory);XCTAssertEqual(try store.piiScanStatus("owned"),status);XCTAssertNil(try store.get("two"));XCTAssertEqual(try recordCount(),1)
    }
    func testHelperCannotAdmitReceiptOutsideSourceTransaction()async throws {
        try await scan([note()]);let record=try XCTUnwrap(store.piiScanStatus("owned").record)
        XCTAssertThrowsError(try store.savePIIScanRecord(record,for:"other"));XCTAssertEqual(try recordCount(),1)
        XCTAssertThrowsError(try store.piiScanFavoriteToken("owned"))
        XCTAssertThrowsError(try store.preservePIIScanAfterFavorite("owned",token:record.contentSHA256))
    }
    func testDeleteAndWipeCascadeReceipts()async throws {
        try await scan([note(),note("two")]);XCTAssertEqual(try recordCount(),2)
        _ = try store.delete("owned");XCTAssertEqual(try recordCount(),1);XCTAssertThrowsError(try store.piiScanStatus("owned"))
        _ = try store.deleteAll();XCTAssertEqual(try recordCount(),0)
    }
    func testFullBackupPreservesRecordedAndInvalidatedStates()async throws {
        try await scan([note(),note("changed")]);try store.setTags("changed",tags:["edited"])
        let before=try store.piiScanStatus("owned"),changed=try store.piiScanStatus("changed"),archive=parent.appendingPathComponent("scan.oswindbackup"),destination=parent.appendingPathComponent("restored")
        _ = try LibraryBackup.create(store:store,destination:archive);_ = try LibraryBackup.inspect(archive);_ = try LibraryBackup.restore(archive,to:destination)
        let other=try MemoryStore(root:destination);defer {try? other.close()}
        XCTAssertEqual(try other.piiScanStatus("owned"),before);XCTAssertEqual(try other.piiScanStatus("changed"),changed)
    }
    func testReadOnlyToolReportsChecksWithoutReturningSourceText()async throws {
        try await scan([note()]);let embedder=LocalEmbedder()
        let output=try await Integration.execute("memory_privacy_check",args:["id":"owned"],store:store,embedder:embedder)
        let value=try XCTUnwrap(output as? [String:Any])
        XCTAssertEqual(value["state"] as? String,"recorded");XCTAssertEqual(value["privacyAcceptance"] as? Bool,false);XCTAssertNil(value["text"])
        do {_ = try await Integration.execute("memory_privacy_check",args:["id":"owned","extra":true],store:store,embedder:embedder);XCTFail("Unknown tool field accepted")} catch {}
        let tool=try XCTUnwrap(Integration.tools.first {$0["name"] as? String=="memory_privacy_check"}),annotations=try XCTUnwrap(tool["annotations"] as? [String:Bool]);XCTAssertEqual(annotations["readOnlyHint"],true)
    }
    func testCancelledReadCannotBecomeAnUncheckedFallback()async throws {
        try await scan([note()]);let store=self.store!
        let task=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try store.piiScanStatus("owned")}
        do {_ = try await task.value;XCTFail("Cancelled status read returned")} catch is CancellationError {} catch {XCTFail("Unexpected: \(error)")}
    }
}

extension PIIScanRecordTests {
    func testBackupCannotReviveAClaimWhoseContentBindingNoLongerMatches()async throws {
        try await scan([note()]);try sql("DROP TRIGGER pii_scan_source_changed")
        var memory=try XCTUnwrap(store.get("owned"));memory.text="Replaced source with old record left behind"
        try store.withRoutineDatabase {db in
            let row=try db.statement("UPDATE memories SET payload=?,text=? WHERE id='owned'");defer {sqlite3_finalize(row)};try db.bind(row,1,json:memory);db.bind(row,2,memory.text);try db.done(row)
        }
        let archive=parent.appendingPathComponent("mismatched.oswindbackup"),destination=parent.appendingPathComponent("mismatched-restored")
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let other=try MemoryStore(root:destination);defer {try? other.close()}
        XCTAssertEqual(try other.piiScanStatus("owned").state,.changed)
        try other.withRoutineDatabase {db in let row=try db.statement("SELECT is_current FROM pii_scan_records WHERE memory_id='owned'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)}
    }
    func testUnsupportedReceiptSurvivesBackupAsUnavailableRatherThanFresh()async throws {
        try await scan([note()]);try mutateReceipt {$0["version"]=99}
        let archive=parent.appendingPathComponent("unknown.oswindbackup"),destination=parent.appendingPathComponent("unknown-restored")
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let other=try MemoryStore(root:destination);defer {try? other.close()}
        XCTAssertEqual(try other.piiScanStatus("owned").state,.unavailable)
        try other.withRoutineDatabase {db in let row=try db.statement("SELECT is_current FROM pii_scan_records WHERE memory_id='owned'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)}
    }
}
