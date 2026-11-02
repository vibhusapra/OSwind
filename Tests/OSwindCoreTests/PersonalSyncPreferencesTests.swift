import XCTest
import CSQLite
@testable import OSwindCore

final class PersonalSyncPreferencesTests:XCTestCase {
    func testAbsentPreferencesAreReadOnlyAndSavedPauseSurvivesReopen()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-intent-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root)
        XCTAssertEqual(try store.personalSyncPreferences(),.init())
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-session-preferences-v1'")},0)
        try store.savePersonalSyncPreferences(.init(reconnectOnLaunch:true,networkEnabled:false));try store.close()
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()}
        XCTAssertEqual(try reopened.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:false))
    }
    func testMalformedOversizeOrIncompleteSavedIntentRefuses()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-intent-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        for value in ["not-json",String(repeating:"x",count:1025),"{\"reconnectOnLaunch\":true}","{\"reconnectOnLaunch\":1,\"networkEnabled\":true}"] {
            try store.withRoutineDatabase {db in
                let row=try db.statement("INSERT OR REPLACE INTO store_metadata(key,value) VALUES('sync-session-preferences-v1',?)");defer {sqlite3_finalize(row)}
                db.bind(row,1,value);try db.done(row)
            }
            XCTAssertThrowsError(try store.personalSyncPreferences())
        }
    }
    func testPortableRecoveryCannotRestoreAutoReconnectIntent()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-intent-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let native=root.appendingPathComponent("native"),store=try MemoryStore(root:native)
        try store.insert(Memory(id:"source",text:"Owned portable content"))
        try store.savePersonalSyncPreferences(.init(reconnectOnLaunch:true,networkEnabled:false));try store.close()
        let backup=root.appendingPathComponent("content.oswindbackup"),fresh=root.appendingPathComponent("restored")
        _=try LibraryRecovery.createBackup(from:native,destination:backup);_=try LibraryBackup.restore(backup,to:fresh)
        let restored=try MemoryStore(root:fresh);defer {try? restored.close()}
        XCTAssertEqual(try restored.get("source")?.text,"Owned portable content")
        XCTAssertEqual(try restored.personalSyncPreferences(),.init())
    }
}
