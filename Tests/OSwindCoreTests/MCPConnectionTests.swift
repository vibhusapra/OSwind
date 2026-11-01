import XCTest
@testable import OSwindCore

final class MCPConnectionTests:XCTestCase {
    func profile(_ name:String="Owned tools")->MCPConnectionProfile {.init(name:name,command:.init(executable:"/owned/not-a-real-executable",arguments:["owned-private-argument"],credentialNames:["API_TOKEN"]))}
    func output(_ text:String="Marigold release belongs to Mira.",protocolVersion:String="2026-07-28",completed:String="2026-11-01T06:00:00Z",hash:String=String(repeating:"a",count:64))->MCPToolOutput {
        .init(tool:"owned_echo",protocolVersion:protocolVersion,commandFingerprint:hash,toolFingerprint:String(repeating:"b",count:64),argumentsFingerprint:String(repeating:"c",count:64),resultJSON:Data("{\"unretained\":\"owned-private-raw-result\"}".utf8),text:text,isError:false,completedAt:completed)
    }
    func testSettingsRoundTripKeepsInertProfilesWithoutCredentials()throws {
        var settings=AppSettings();let p=profile();settings.mcpConnections=[p]
        let bytes=try JSONEncoder().encode(settings),decoded=try JSONDecoder().decode(AppSettings.self,from:bytes)
        XCTAssertEqual(decoded.mcpConnections,[p]);XCTAssertFalse(decoded.captureOnLaunch)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("credentialValues"))
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8)).mcpConnections.isEmpty)
    }
    func testMalformedAndDuplicateSavedProfilesFailClosed()throws {
        var settings=AppSettings();let p=profile();settings.mcpConnections=[p,p]
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).mcpConnections.isEmpty)
        var broken=p;broken.command.executable="relative";settings.mcpConnections=[broken]
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).mcpConnections.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:Data(#"{"mcpConnections":"bad"}"#.utf8)).mcpConnections.isEmpty)
    }
    func testProfileBoundsAndReservedCredentialNames()throws {
        XCTAssertThrowsError(try MCPConnectionProfile.validate((0..<9).map {profile("Owned \($0)")}))
        var p=profile();p.name="\n";XCTAssertThrowsError(try p.validate());p=profile();p.id="not-a-profile";XCTAssertThrowsError(try p.validate())
        p=profile();p.command.credentialNames=["DYLD_INSERT_LIBRARIES"];XCTAssertThrowsError(try p.validate())
        XCTAssertNoThrow(try profile().validate(),"Configuration validation must not probe or execute the nonexistent path")
    }
    func testAuthorityComparisonIsByteExactDespiteUnicodeCanonicalEquality()throws {
        var a=profile("café"),b=a;b.name="cafe\u{301}";XCTAssertNotEqual(a,b)
        b=a;a.command.arguments=["café"];b.command.arguments=["cafe\u{301}"];XCTAssertNotEqual(a.command,b.command)
        a.command.executable="/owned/café";b.command.executable="/owned/cafe\u{301}";XCTAssertNotEqual(a.command,b.command)
    }
    func testQuietRestoreClearsAllExternalConnectionChoices() {
        var settings=AppSettings();settings.mcpConnections=[profile()]
        XCTAssertTrue(LibraryBackup.quietSettings(settings).mcpConnections.isEmpty)
        XCTAssertEqual(settings.mcpConnections.count,1)
    }
    func testResultDraftKeepsTextAndProvenanceButNotArgumentsPathsOrRawContent()throws {
        let p=profile(),draft=try MCPResultSourceDraft(profile:p,callID:UUID().uuidString.lowercased(),output:output()),raw=String(decoding:draft.batch,as:UTF8.self)
        XCTAssertTrue(raw.contains("Marigold release"));XCTAssertTrue(raw.contains("Unverified external MCP"));XCTAssertTrue(raw.contains("2026-07-28"))
        XCTAssertFalse(raw.contains(p.command.executable));XCTAssertFalse(raw.contains("owned-private-argument"));XCTAssertFalse(raw.contains("owned-private-raw-result"));XCTAssertFalse(raw.contains("API_TOKEN"))
    }
    func testRepeatedExplicitSaveHasOneStableOriginalSource()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-mcp-source-"+UUID().uuidString),store=try MemoryStore(root:root);defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let p=profile(),call=UUID().uuidString.lowercased(),a=try MCPResultSourceDraft(profile:p,callID:call,output:output()),b=try MCPResultSourceDraft(profile:p,callID:call,output:output())
        XCTAssertEqual(a.sourceID,b.sourceID)
        _ = try store.importCollectorBatch(a.batch);_ = try store.importCollectorBatch(b.batch)
        XCTAssertEqual(try store.stats().count,1);let source=try XCTUnwrap(store.get(a.sourceID));XCTAssertEqual(source.bundleID,"org.oswind.mcp");XCTAssertTrue(source.text.contains("Marigold release"))
        let other=try MCPResultSourceDraft(profile:p,callID:UUID().uuidString.lowercased(),output:output());XCTAssertNotEqual(a.sourceID,other.sourceID)
    }
    func testResultAdmissionUsesPatternRedactionAndApplicationExclusion()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-mcp-privacy-"+UUID().uuidString),store=try MemoryStore(root:root);defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let draft=try MCPResultSourceDraft(profile:profile(),callID:UUID().uuidString.lowercased(),output:output("Marigold result. password=owned-only-secret"))
        _ = try store.importCollectorBatch(draft.batch);let saved=try XCTUnwrap(store.get(draft.sourceID));XCTAssertFalse(saved.text.contains("owned-only-secret"));XCTAssertTrue(saved.text.contains("[REDACTED]"))
        var policy=PrivacyPolicy();policy.excludedApps.append("org.oswind.mcp")
        let excluded=try MCPResultSourceDraft(profile:profile(),callID:UUID().uuidString.lowercased(),output:output());let result=try store.importCollectorBatch(excluded.batch,policy:policy)
        XCTAssertEqual(result.imported,0);XCTAssertNil(try store.get(excluded.sourceID))
    }
    func testEmptyNULAndOversizedTextCannotBecomeRecordedSources() {
        for text in ["  ","x\0y",String(repeating:"x",count:262145)] {XCTAssertThrowsError(try MCPResultSourceDraft(profile:profile(),callID:UUID().uuidString.lowercased(),output:output(text)))}
    }
    func testIncompleteProvenanceIsRejectedBeforeAnyImport() {
        for value in [output(protocolVersion:"unknown"),output(completed:"not-a-date"),output(hash:"missing")] {XCTAssertThrowsError(try MCPResultSourceDraft(profile:profile(),callID:UUID().uuidString.lowercased(),output:value))}
    }
    func testAChangedSettingsSnapshotRefusesStaleResultAdmission()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-mcp-snapshot-"+UUID().uuidString),store=try MemoryStore(root:root);defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        var settings=AppSettings();settings.mcpConnections=[profile()];try settings.save(root:root)
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()};let draft=try MCPResultSourceDraft(profile:settings.mcpConnections[0],callID:UUID().uuidString.lowercased(),output:output())
        settings.privacy.excludedApps.append("org.oswind.mcp");try settings.save(root:root)
        XCTAssertThrowsError(try store.importCollectorBatch(draft.batch,policy:snapshot.settings.privacy,settingsSnapshot:snapshot));XCTAssertNil(try store.get(draft.sourceID))
    }
}
