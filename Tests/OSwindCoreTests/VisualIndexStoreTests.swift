import XCTest
import CSQLite
import Darwin
@testable import OSwindCore

final class VisualIndexStoreTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let model="test-visual"
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-store-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {try? store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    @discardableResult func image(_ id:String="one",app:String="Photos",text:String="",time:Double=100,vector:[Float]=[1,0]) throws -> Memory {
        let memory=Memory(id:id,timestamp:Date(timeIntervalSince1970:time),app:app,bundleID:"test.photos",text:text,imagePath:"images/\(id).dat")
        try Data(("authored pixels "+id).utf8).write(to:root.appendingPathComponent(memory.imagePath!));try store.insert(memory)
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:id));defer {snapshot.release()}
        XCTAssertEqual(try store.saveVisualVectors([.init(point:snapshot.plan.points[0],decodedTime:nil,vector:vector)],snapshot:snapshot,modelID:model),1)
        return memory
    }
    func testImageOnlySourceHasPersistedSearchAndSeparateTextIndex() throws {
        let memory=try image();let coverage=try store.visualCoverage(modelID:model)
        XCTAssertEqual(coverage.sources,1);XCTAssertEqual(coverage.indexedFrames,1)
        XCTAssertEqual(try store.semanticIndexes(),[:])
        let hits=try store.searchVisual(SearchFilter(query:"a red shape"),vector:[1,0],modelID:model).hits
        XCTAssertEqual(hits.map(\.id),[memory.id]);XCTAssertEqual(hits.first?.visual?.frameOrdinal,0);XCTAssertNil(hits.first?.passage)
        XCTAssertEqual(try store.hydrate(hits).first?.visual,hits.first?.visual)
        try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model).hits.map(\.id),[memory.id])
    }
    func testVisualScoresAreRankedWithoutUncalibratedConfidenceCutoff() throws {
        try image("weak",vector:[0.05,1]);try image("negative",vector:[-0.1,1])
        let ranked=try store.searchVisual(SearchFilter(limit:2),vector:[1,0],modelID:model).hits
        XCTAssertEqual(ranked.map(\.id),["weak","negative"])
        XCTAssertLessThan(ranked[0].score,0.12);XCTAssertLessThan(ranked[1].score,0)
        XCTAssertTrue(try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model,minimumSimilarity:0.12).hits.isEmpty)
    }
    func testAllScopesAndExplicitContentConstraintsApply() throws {
        try image("one",app:"Photos",text:"red car",time:100,vector:[1,0]);try image("two",app:"Browser",text:"blue boat",time:200,vector:[0.8,0.2])
        try store.setFavorite("one",value:true);try store.setTags("one",tags:["trip"])
        let filters=[SearchFilter(app:"Photos"),SearchFilter(start:Date(timeIntervalSince1970:99),end:Date(timeIntervalSince1970:150)),SearchFilter(favoritesOnly:true),SearchFilter(tag:"trip")]
        for filter in filters {XCTAssertEqual(try store.searchVisual(filter,vector:[1,0],modelID:model).hits.map(\.id),["one"])}
        XCTAssertTrue(try store.searchVisual(SearchFilter(kind:.audio),vector:[1,0],modelID:model).hits.isEmpty)
        let phrase=try SearchExpressionPlan.make("\"blue boat\"")
        XCTAssertEqual(try store.searchVisual(SearchFilter(query:"\"blue boat\""),vector:[1,0],modelID:model,expression:phrase).hits.map(\.id),["two"])
    }
    func testChangedBytesArePrunedAndOldHitCannotHydrate() throws {
        try image();let hits=try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model).hits
        try Data("replacement pixels".utf8).write(to:root.appendingPathComponent("images/one.dat"))
        let result=try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model)
        XCTAssertTrue(result.hits.isEmpty);XCTAssertEqual(result.invalidMedia,1);XCTAssertThrowsError(try store.hydrate(hits))
    }
    func testSameSizeInPlaceChangeWithRestoredModificationTimeStillRehashes() throws {
        try image();let hits=try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model).hits
        let path=root.appendingPathComponent("images/one.dat");var before=stat();XCTAssertEqual(lstat(path.path,&before),0)
        let file=try FileHandle(forWritingTo:path);try file.seek(toOffset:0);try file.write(contentsOf:Data([0x00]));try file.close()
        let times=[before.st_atimespec,before.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer {utimensat(AT_FDCWD,path.path,$0.baseAddress,0)},0)
        var after=stat();XCTAssertEqual(lstat(path.path,&after),0)
        XCTAssertEqual(after.st_ino,before.st_ino);XCTAssertEqual(after.st_size,before.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_sec,before.st_mtimespec.tv_sec);XCTAssertEqual(after.st_mtimespec.tv_nsec,before.st_mtimespec.tv_nsec)
        let result=try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model)
        XCTAssertTrue(result.hits.isEmpty);XCTAssertEqual(result.invalidMedia,1);XCTAssertThrowsError(try store.hydrate(hits))
    }
    func testMetadataChangeInvalidatesButFavoriteAndTagsPreserve() throws {
        var memory=try image();try store.setFavorite(memory.id,value:true);try store.setTags(memory.id,tags:["trip"])
        XCTAssertEqual(try store.visualCoverage(modelID:model).indexedSources,1)
        memory.bundleID="changed";try store.insert(memory)
        XCTAssertEqual(try store.visualCoverage(modelID:model).indexedSources,0)
        XCTAssertTrue(try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model).hits.isEmpty)
    }
    func testLateOrReleasedSnapshotCannotAdmitVectors() throws {
        var memory=try image();let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        let records=[VisualFrameVector(point:snapshot.plan.points[0],decodedTime:nil,vector:[0,1])]
        memory.title="changed after inference began";try store.insert(memory)
        XCTAssertThrowsError(try store.saveVisualVectors(records,snapshot:snapshot,modelID:model))
        XCTAssertEqual(try store.visualCoverage(modelID:model).indexedSources,0)
        snapshot.release();XCTAssertThrowsError(try store.saveVisualVectors(records,snapshot:snapshot,modelID:model))
    }
    func testInvalidBatchDoesNotReplaceExistingVectorsAndWrongLibraryRefuses() throws {
        try image();let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:"one"));defer {snapshot.release()}
        for vector:[Float] in [[],[0,0],[.nan,1],[.infinity,1]] {
            XCTAssertThrowsError(try store.saveVisualVectors([.init(point:snapshot.plan.points[0],decodedTime:nil,vector:vector)],snapshot:snapshot,modelID:model))
        }
        XCTAssertEqual(try store.visualCoverage(modelID:model).indexedSources,1)
        let other=try MemoryStore(root:root.appendingPathComponent("other"));defer {try? other.close()}
        XCTAssertThrowsError(try other.saveVisualVectors([.init(point:snapshot.plan.points[0],decodedTime:nil,vector:[1,0])],snapshot:snapshot,modelID:model))
        XCTAssertEqual(try other.visualCoverage(modelID:model).indexedSources,0)
    }
    func testDeletionAndWholeWipeCascadeAllVisualState() throws {
        try image("one");try image("two")
        _ = try store.delete("one");XCTAssertEqual(try store.visualCoverage(modelID:model).indexedSources,1)
        _ = try store.wipeLibrary();XCTAssertEqual(try store.visualCoverage(modelID:model).sources,0)
        try store.withRoutineDatabase {db in for table in ["visual_vectors","visual_manifests","visual_sources"] {let row=try db.statement("SELECT COUNT(*) FROM \(table)");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)}}
    }
    func testVideoPinIsLibraryScopedAndCompleteFrameSetRequired() throws {
        var memory=Memory(id:"video",app:"Fixture",text:"");memory.videoPath="video/one.mov";memory.visualRecording=VisualRecording(duration:3,width:640,height:480,codec:"hevc",hardwareRequired:true,frames:[VisualFrame(time:0,text:"first"),VisualFrame(time:1.5,text:"second")]);memory.text=memory.visualRecording!.text
        try Data("authored encoded video fixture".utf8).write(to:root.appendingPathComponent(memory.videoPath!));try store.insert(memory)
        let snapshot=try XCTUnwrap(VisualVideoSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        try autoreleasepool {
            let library=try BackupFileTree(root:root),pinned=try BackupFileTree(root:snapshot.url.deletingLastPathComponent())
            XCTAssertTrue(try library.isAncestor(of:pinned))
            XCTAssertEqual(snapshot.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,".staging")
        }
        let records=snapshot.plan.points.map {VisualFrameVector(point:$0,decodedTime:$0.time,vector:$0.ordinal==0 ? [0,1]:[1,0])}
        XCTAssertThrowsError(try store.saveVisualVectors(Array(records.prefix(1)),snapshot:snapshot,modelID:model))
        XCTAssertEqual(try store.saveVisualVectors(records,snapshot:snapshot,modelID:model),2)
        let hits=try store.searchVisual(SearchFilter(),vector:[1,0],modelID:model).hits
        XCTAssertEqual(hits.count,1);XCTAssertEqual(hits[0].visual?.frameOrdinal,1);XCTAssertEqual(hits[0].visual?.decodedTime,1.5)
        let path=snapshot.url;snapshot.release();XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
    }
    func testSchema18UpgradeBackfillsVisualSources() throws {
        try image();try store.close();store=nil
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"DROP TABLE visual_vectors; DROP TABLE visual_manifests; DROP TABLE visual_sources; PRAGMA user_version=18",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        store=try MemoryStore(root:root);XCTAssertEqual(MemoryStore.schemaVersion,25)
        let coverage=try store.visualCoverage(modelID:model);XCTAssertEqual(coverage.sources,1);XCTAssertEqual(coverage.indexedSources,0)
    }
    func testBackupRestoreRemapsMediaAndPreservesVerifiedVisualVectors() throws {
        try image();let container=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-restore-"+UUID().uuidString);try Paths.ensure(container);defer {try? FileManager.default.removeItem(at:container)}
        let archive=container.appendingPathComponent("copy.oswindbackup"),destination=container.appendingPathComponent("restored")
        _ = try LibraryBackup.create(store:store,destination:archive);let info=try LibraryBackup.restore(archive,to:destination)
        XCTAssertEqual(info.discardedVisualIndexes,0)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        XCTAssertNotEqual(try restored.get("one")?.imagePath,"images/one.dat")
        XCTAssertEqual(try restored.visualCoverage(modelID:model).indexedSources,1)
        XCTAssertEqual(try restored.searchVisual(SearchFilter(),vector:[1,0],modelID:model).hits.map(\.id),["one"])
    }
    func testRestoreReportsStaleMediaIndexWithoutLosingHistory() throws {
        try image();try Data("replaced before backup".utf8).write(to:root.appendingPathComponent("images/one.dat"))
        let container=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-stale-"+UUID().uuidString);try Paths.ensure(container);defer {try? FileManager.default.removeItem(at:container)}
        let archive=container.appendingPathComponent("copy.oswindbackup"),destination=container.appendingPathComponent("restored")
        _ = try LibraryBackup.create(store:store,destination:archive);let info=try LibraryBackup.restore(archive,to:destination)
        XCTAssertEqual(info.discardedVisualIndexes,1)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        XCTAssertNotNil(try restored.get("one"));XCTAssertEqual(try restored.visualCoverage(modelID:model).indexedSources,0)
    }
}
