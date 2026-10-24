import XCTest
@testable import OSwindCore

final class StoreTests: XCTestCase {
    var root: URL!
    var store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func add(_ id: String = UUID().uuidString, text: String = "A searchable memory", app: String = "Safari", at: Double = 100, kind: MemoryKind = .screen, vector: [Float]? = nil) throws { try store.insert(Memory(id:id,timestamp:Date(timeIntervalSince1970:at),kind:kind,app:app,title:"Title \(id)",text:text,embedding:vector,embeddingModel:vector == nil ? nil : "test")) }
    func testDurabilityAndUnicode() throws {
        try add("one",text:"Café résumé 日本語 SwiftUI")
        store = nil; store = try MemoryStore(root:root)
        XCTAssertEqual(try store.get("one")?.text,"Café résumé 日本語 SwiftUI")
        XCTAssertEqual(try store.search(SearchFilter(query:"cafe"),mode:.keyword).map(\.id),["one"])
    }
    func testFTSDeletionAndUpsert() throws {
        try add("one",text:"obsolete content"); try add("one",text:"replacement content")
        XCTAssertTrue(try store.search(SearchFilter(query:"obsolete"),mode:.keyword).isEmpty)
        XCTAssertEqual(try store.search(SearchFilter(query:"replacement"),mode:.keyword).count,1)
        try store.delete("one"); XCTAssertTrue(try store.search(SearchFilter(query:"replacement"),mode:.keyword).isEmpty)
    }
    func testFiltersAndExclusiveEnd() throws {
        try add("a",app:"Safari",at:100); try add("b",app:"Xcode",at:200,kind:.audio); try add("c",app:"Safari",at:300)
        XCTAssertEqual(try store.search(SearchFilter(app:"Safari",start:Date(timeIntervalSince1970:100),end:Date(timeIntervalSince1970:300))).map(\.id),["a"])
        XCTAssertEqual(try store.search(SearchFilter(kind:.audio)).map(\.id),["b"])
        try store.setFavorite("a",value:true); XCTAssertEqual(try store.search(SearchFilter(favoritesOnly:true)).map(\.id),["a"])
        try store.setTags("b",tags:["project","project",""]); XCTAssertEqual(try store.search(SearchFilter(tag:"project")).map(\.id),["b"])
    }
    func testSemanticAndMetadataPreservesVectors() throws {
        try add("a",text:"cat",vector:[1,0]); try add("b",text:"dog",vector:[0,1]); try store.setFavorite("a",value:true)
        let hits = try store.search(SearchFilter(query:"feline"),mode:.semantic,vector:[1,0],modelID:"test")
        XCTAssertEqual(hits.first?.id,"a"); XCTAssertEqual(try store.stats().embedded,2)
        XCTAssertTrue(try store.search(SearchFilter(query:"feline"),mode:.semantic,vector:[1,0],modelID:"other").isEmpty)
    }
    func testFTSSyntaxAndInjectionAreData() throws {
        try add("a",text:"hello quote OR test")
        for query in ["\"", "*", "' OR 1=1 --", "NEAR(foo)", "\" AND", "hello: world", "日本語"] {
            // Advanced syntax may reject malformed expressions, but never as SQL.
            do { _ = try store.search(SearchFilter(query:query),mode:.keyword) }
            catch { XCTAssertTrue(error is QuerySyntaxError,"Unexpected error: \(error)") }
            let literal = try SearchExpressionPlan.make(query,interpret:false)
            XCTAssertNoThrow(try store.search(SearchFilter(query:query),mode:.keyword,expression:literal))
        }
        XCTAssertEqual(try store.stats().count,1)
    }
    func testAssetPathTraversalAndSymlinks() throws {
        XCTAssertNil(store.assetURL("settings.json")); XCTAssertNil(store.assetURL("images")); XCTAssertNil(store.assetURL("../outside")); XCTAssertNil(store.assetURL("/tmp/outside"))
        let link = root.appendingPathComponent("images/escape"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:URL(fileURLWithPath:"/tmp")); XCTAssertNil(store.assetURL("images/escape/test.jpg"))
        XCTAssertThrowsError(try store.insert(Memory(text:"x",imagePath:"../private.jpg")))
    }
    func testDeleteRemovesMediaAndText() throws {
        let file = root.appendingPathComponent("images/a.jpg"); try Data([1,2,3]).write(to:file)
        try store.insert(Memory(id:"a",text:"unique-test-text",imagePath:"images/a.jpg")); try store.delete("a")
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path)); XCTAssertNil(try store.get("a")); XCTAssertTrue(try store.search(SearchFilter(query:"unique-test-text")).isEmpty)
    }
    func testRetentionPrunesFavoritesAsWell() throws {
        try add("old",at:100); try add("new",at:200); try store.setFavorite("old",value:true)
        XCTAssertEqual(try store.prune(before:Date(timeIntervalSince1970:150)),1); XCTAssertEqual(try store.stats().count,1)
    }
    func testExportImportRedactsAndStripsUntrustedAssets() throws {
        try store.insert(Memory(id:"a",text:"password=secret-value",imagePath:"images/a.jpg",tags:["research"]))
        let file = root.appendingPathComponent("export.json"); try store.exportJSON(to:file); try store.deleteAll()
        XCTAssertEqual(try store.importJSON(from:file),1); let result = try XCTUnwrap(store.get("a")); XCTAssertEqual(result.text,"[REDACTED]"); XCTAssertNil(result.imagePath); XCTAssertEqual(result.tags,["research"])
    }
    func testImportIsTransactional() throws {
        let file = root.appendingPathComponent("bad.json")
        let memories = [Memory(id:"good",text:"okay"), Memory(id:"",text:"invalid")]; try JSONEncoder().encode(memories).write(to:file)
        XCTAssertThrowsError(try store.importJSON(from:file)); XCTAssertEqual(try store.stats().count,0)
    }
    func testConcurrentReadersAndWriters() throws {
        let target = store!; let group = DispatchGroup(); let failureLock = NSLock(); var errors = [Error]()
        for i in 0..<80 { group.enter(); DispatchQueue.global().async { defer { group.leave() }; do { try target.insert(Memory(id:"\(i)",text:"concurrent \(i)")); _ = try target.search(SearchFilter(query:"concurrent")) } catch { failureLock.lock(); errors.append(error); failureLock.unlock() } } }
        XCTAssertEqual(group.wait(timeout:.now()+20),.success); XCTAssertTrue(errors.isEmpty); XCTAssertEqual(try store.stats().count,80)
    }
    func testStorageBudgetReclaimsDatabase() throws {
        for i in 0..<100 { try add("large-\(i)",text:String(repeating:"evidence \(i) ",count:1000)) }
        let initial = store.diskBytes(); let budget = initial * 3 / 4
        _ = try store.prune(before:Date(timeIntervalSince1970:0),maxBytes:budget)
        XCTAssertLessThanOrEqual(store.diskBytes(),budget)
        XCTAssertGreaterThan(try store.stats().count,0)
    }
    func testDeleteAllRebuildsIndex() throws { try add(); try store.deleteAll(); XCTAssertEqual(try store.stats().count,0); try add("new"); XCTAssertEqual(try store.search(SearchFilter(query:"searchable")).count,1) }
}
