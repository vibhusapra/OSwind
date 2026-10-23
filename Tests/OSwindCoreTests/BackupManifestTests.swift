import XCTest
@testable import OSwindCore

final class BackupManifestTests: XCTestCase {
    var root: URL!, tree: BackupFileTree!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); tree = try BackupFileTree(root:root,writable:true) }
    override func tearDownWithError() throws { tree = nil; try? FileManager.default.removeItem(at:root) }
    func index(_ name: String = UUID().uuidString) throws -> BackupManifestIndex { try BackupManifestIndex(root.appendingPathComponent(name+".sqlite")) }
    func entry(_ path: String, bytes: Int64 = 42) -> BackupMediaEntry { BackupMediaEntry(sourcePath:path,member:BackupMediaEntry.member(for:path),bytes:bytes,sha256:String(repeating:"a",count:64)) }
    func testOpaqueMappingsPreserveCaseUnicodeAndControlCharacters() throws {
        let paths = ["images/A.jpg","images/a.jpg","images/é.jpg","images/e\u{301}.jpg","audio/a\nb.wav"]
        XCTAssertEqual(Set(paths.map(BackupMediaEntry.member)).count,paths.count)
        let entries = paths.map { entry($0) }
        for item in entries { XCTAssertNoThrow(try item.validate()); XCTAssertTrue(item.member.hasPrefix("media/")); XCTAssertEqual(item.member.count,70) }
    }
    func testInvalidPathsDigestsAndSizesAreRejected() throws {
        for path in ["../outside","settings.json","/images/a","images/../a","images/a\0b","images//a"] { XCTAssertThrowsError(try entry(path).validate()) }
        var item = entry("images/a"); item.bytes = -1; XCTAssertThrowsError(try item.validate())
        item = entry("images/a"); item.member = "media/../escape"; XCTAssertThrowsError(try item.validate())
        item = entry("images/a"); item.sha256 = String(repeating:"A",count:64); XCTAssertThrowsError(try item.validate())
    }
    func testPendingPinsAttemptsAndDigestStateRemainDistinct() throws {
        let index = try index(), path = "images/a.jpg"
        XCTAssertFalse(try index.register(path).pinned); try index.markPinned(path); XCTAssertTrue(try index.register(path).pinned)
        XCTAssertEqual(try index.activeCount,0); try index.markActive(path); XCTAssertEqual(try index.activeCount,1)
        XCTAssertThrowsError(try index.entry(for:path)); try index.record(entry(path)); XCTAssertEqual(try index.entry(for:path),entry(path)); XCTAssertEqual(try index.activeBytes,42)
        try index.beginAttempt(); XCTAssertEqual(try index.activeCount,0); XCTAssertNil(try index.entry(for:path)); XCTAssertTrue(try index.register(path).pinned)
    }
    func testStreamingManifestRoundTripAndDuplicateRejection() throws {
        let first = try index(), items = [entry("images/A.jpg"),entry("images/a.jpg"),entry("audio/line\nbreak.wav",bytes:0)]
        for item in items { try first.record(item) }
        let digest = try first.write(to:tree), second = try index()
        try second.load(from:tree,expectedCount:3,expectedDigest:digest)
        XCTAssertEqual(try second.activeCount,3); XCTAssertEqual(try second.activeBytes,84)
        for item in items { XCTAssertEqual(try second.entry(for:item.sourcePath),item); XCTAssertTrue(try second.contains(member:item.member)) }
        XCTAssertFalse(try second.contains(member:"media/unknown"))
        XCTAssertThrowsError(try second.record(items[0],rejectDuplicate:true))
    }
    func testManifestChecksumCountTruncationBlankAndLineBounds() throws {
        let item = entry("images/a.jpg"), line = try JSONEncoder().encode(item)
        var complete = line; complete.append(10); try tree.write(complete,as:"media.ndjson"); let digest = try tree.digest("media.ndjson")
        XCTAssertThrowsError(try index().load(from:tree,expectedCount:0,expectedDigest:digest))
        XCTAssertThrowsError(try index().load(from:tree,expectedCount:2,expectedDigest:digest))
        XCTAssertThrowsError(try index().load(from:tree,expectedCount:1,expectedDigest:BackupFileDigest(bytes:digest.bytes,sha256:String(repeating:"0",count:64))))
        try tree.write(line,as:"truncated"); XCTAssertThrowsError(try BackupLineReader.read(tree,"truncated") { _ in })
        try tree.write(Data([10]),as:"blank"); XCTAssertThrowsError(try BackupLineReader.read(tree,"blank") { _ in })
        XCTAssertThrowsError(try BackupLineReader.read(tree,"media.ndjson",maxLineBytes:8) { _ in })
    }
    func testDuplicateManifestLinesAndMutationCannotValidate() throws {
        let item = entry("images/a.jpg"); var line = try JSONEncoder().encode(item); line.append(10)
        try tree.write(line+line,as:"media.ndjson"); let digest = try tree.digest("media.ndjson")
        XCTAssertThrowsError(try index().load(from:tree,expectedCount:2,expectedDigest:digest))
        var changed = false
        XCTAssertThrowsError(try BackupLineReader.read(tree,"media.ndjson") { _ in
            if !changed { changed = true; let file = try FileHandle(forWritingTo:self.root.appendingPathComponent("media.ndjson")); try file.seekToEnd(); try file.write(contentsOf:line); try file.close() }
        })
        XCTAssertTrue(changed)
    }
    func testEmptyManifestAndPagedUpdatesDoNotSkipOrDuplicate() throws {
        try tree.write(Data(),as:"media.ndjson"); let empty = try index(); try empty.load(from:tree,expectedCount:0,expectedDigest:try tree.digest("media.ndjson")); XCTAssertEqual(try empty.activeCount,0)
        let index = try index()
        for i in 0..<300 { let path = String(format:"images/%05d.jpg",i); _ = try index.register(path); try index.markActive(path) }
        var count = 0
        try index.forEachActive { pending in count += 1; try index.record(self.entry(pending.sourcePath)) }
        XCTAssertEqual(count,300); XCTAssertEqual(try index.activeCount,300); XCTAssertEqual(try index.activeBytes,12600)
    }
    func testTotalByteOverflowIsAnError() throws {
        let index = try index(); try index.record(entry("images/a",bytes:Int64.max)); try index.record(entry("images/b",bytes:1))
        XCTAssertThrowsError(try index.activeBytes)
    }
}
