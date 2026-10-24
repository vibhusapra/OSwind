import XCTest
import AppKit
import CSQLite
@testable import OSwindCore

final class SnapshotRegionTests:XCTestCase {
    let a="11111111-1111-4111-8111-111111111111",b="22222222-2222-4222-8222-222222222222"
    func testLegacySettingsPreserveFocusedWindowAndAllDisplaysDefaults() throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8));XCTAssertFalse(old.allDisplays);XCTAssertEqual(old.snapshotRegions,SnapshotRegionSettings())
        let displays=try JSONDecoder().decode(AppSettings.self,from:Data(#"{"allDisplays":true}"#.utf8));XCTAssertTrue(displays.allDisplays);XCTAssertNil(displays.snapshotRegions.selectedDisplays)
    }
    func testSelectionDistinguishesAllNoneAndSpecificMissingScreenWithoutFallback() throws {
        var value=SnapshotRegionSettings();XCTAssertTrue(value.includes(a));XCTAssertTrue(value.includes(b))
        value.selectedDisplays=[];XCTAssertFalse(value.includes(a));XCTAssertFalse(value.includes(b))
        value.selectedDisplays=[a];XCTAssertTrue(value.includes(a));XCTAssertFalse(value.includes(b))
        let decoded=try JSONDecoder().decode(SnapshotRegionSettings.self,from:JSONEncoder().encode(value));XCTAssertEqual(decoded,value)
    }
    func testDisplayResolutionNeverSubstitutesAnotherScreenAndRejectsAmbiguity() throws {
        let first=SnapshotDisplayDescriptor(identifier:a,displayID:1,frame:CGRect(x:-2000,y:0,width:2000,height:1000),size:CGSize(width:2000,height:1000)),other=SnapshotDisplayDescriptor(identifier:b,displayID:2,frame:CGRect(x:0,y:0,width:1000,height:1000),size:CGSize(width:1000,height:1000))
        var settings=SnapshotRegionSettings();settings.selectedDisplays=[a]
        XCTAssertEqual(try settings.resolved([first,other]),[first]);XCTAssertEqual(try settings.resolved([other]),[])
        var replacement=first;replacement.displayID=3
        XCTAssertThrowsError(try settings.resolved([first,replacement,other]));XCTAssertFalse(first.current(in:[replacement,other]))
        replacement=first;replacement.frame.origin.x=0;XCTAssertFalse(first.current(in:[replacement,other]));XCTAssertTrue(first.current(in:[first,other]))
    }
    func testMalformedNewSelectionKeepsLegacySettingsButCapturesNoDisplays() throws {
        for raw in [#"{"selectedDisplays":"wrong"}"#,#"{"selectedDisplays":["not a display"]}"#,#"{"selectedDisplays":["11111111-1111-4111-8111-111111111111","11111111-1111-4111-8111-111111111111"]}"#,#"{"focusedWindowCrop":{"x":0.9,"y":0,"width":0.5,"height":1}}"#,"null"] {
            let data=Data((#"{"profile":"light","allDisplays":true,"snapshotRegions":"#+raw+"}").utf8)
            let decoded=try JSONDecoder().decode(AppSettings.self,from:data)
            XCTAssertEqual(decoded.profile,.light);XCTAssertTrue(decoded.allDisplays);XCTAssertEqual(decoded.snapshotRegions,.disabled);XCTAssertFalse(decoded.snapshotRegions.includes(a))
        }
    }
    func testMalformedFocusedCropStaysBlockedAcrossSaveInsteadOfWideningScope() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let decoded=try JSONDecoder().decode(AppSettings.self,from:Data(#"{"snapshotRegions":{"focusedWindowCrop":{"x":0,"y":0,"width":2,"height":1}}}"#.utf8))
        XCTAssertFalse(decoded.allDisplays);XCTAssertTrue(decoded.snapshotRegions.blocked);XCTAssertFalse(decoded.snapshotRegions.valid)
        try decoded.save(root:root);let reopened=AppSettings.load(root:root);XCTAssertTrue(reopened.snapshotRegions.blocked);XCTAssertFalse(reopened.snapshotRegions.valid)
    }
    func testCanonicalUUIDAndCropRoundTripAcrossSettingsSave() throws {
        let id="AABBCCDD-1234-4567-8123-123456789ABC",root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let decoded=try JSONDecoder().decode(SnapshotRegionSettings.self,from:Data((#"{"selectedDisplays":[""#+id.lowercased()+#""],"displayCrops":{""#+id.lowercased()+#"":{"x":0.1,"y":0.2,"width":0.6,"height":0.5}}}"#).utf8))
        XCTAssertEqual(decoded.selectedDisplays,[id]);XCTAssertNotNil(decoded.displayCrops[id]);var settings=AppSettings();settings.allDisplays=true;settings.snapshotRegions=decoded;try settings.save(root:root);XCTAssertEqual(AppSettings.load(root:root),settings)
    }
    func testInvalidFiniteBoundsNeverBecomeFullSource() {
        for crop in [SnapshotRegion(x:-0.1),SnapshotRegion(x:1),SnapshotRegion(width:0),SnapshotRegion(height:-1),SnapshotRegion(width:1.1),SnapshotRegion(x:.nan),SnapshotRegion(height:.infinity),SnapshotRegion(x:0.8,width:0.3)] {
            XCTAssertFalse(crop.valid);XCTAssertThrowsError(try crop.rect(in:CGSize(width:100,height:100)))
        }
        XCTAssertThrowsError(try SnapshotRegion().rect(in:.zero));XCTAssertThrowsError(try SnapshotRegion(width:0.001).rect(in:CGSize(width:100,height:100)))
    }
    func testDisplayLocalGeometryAndOutputScalingRespectAspectAndProfileLimit() throws {
        let crop=SnapshotRegion(x:0.25,y:0.1,width:0.5,height:0.4),result=try SnapshotRegionGeometry(size:CGSize(width:2560,height:1440),region:crop,maximumDimension:1920)
        XCTAssertEqual(result.sourceRect,CGRect(x:640,y:144,width:1280,height:576));XCTAssertEqual(result.outputWidth,1920);XCTAssertEqual(result.outputHeight,864)
        let full=try SnapshotRegionGeometry(size:CGSize(width:100,height:50),region:nil,maximumDimension:1920);XCTAssertEqual(full.outputWidth,200);XCTAssertEqual(full.outputHeight,100)
        XCTAssertThrowsError(try SnapshotRegionGeometry(size:CGSize(width:100,height:50),region:crop,maximumDimension:0))
    }
    func testOwnedBitmapCropRoundsInwardAndContainsOnlySelectedPixels() throws {
        let context=try XCTUnwrap(CGContext(data:nil,width:10,height:10,bitsPerComponent:8,bytesPerRow:40,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:10,height:10));context.setFillColor(NSColor.blue.cgColor);context.fill(CGRect(x:5,y:0,width:5,height:10))
        let image=try XCTUnwrap(context.makeImage()),crop=try SnapshotRegion(x:0.51,y:0.11,width:0.39,height:0.79).crop(image)
        XCTAssertEqual(crop.width,3);XCTAssertEqual(crop.height,7)
        let read=try XCTUnwrap(CGContext(data:nil,width:3,height:7,bitsPerComponent:8,bytesPerRow:12,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));read.draw(crop,in:CGRect(x:0,y:0,width:3,height:7))
        let pixels=try XCTUnwrap(read.data).assumingMemoryBound(to:UInt8.self)
        for index in 0..<21 {XCTAssertEqual(pixels[index*4],0);XCTAssertEqual(pixels[index*4+2],255)}
    }
    func testUnreadableExistingSettingsBlockAreaAndMaintenanceWhileMissingSettingsUseDefaults() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertEqual(AppSettings.load(root:root),AppSettings());try Paths.ensure(root)
        for content in ["", "{", #"{"profile":"unsupported"}"#] {
            try Data(content.utf8).write(to:root.appendingPathComponent("settings.json"))
            let settings=AppSettings.load(root:root);XCTAssertTrue(settings.snapshotRegions.blocked);XCTAssertFalse(settings.snapshotRegions.valid);XCTAssertFalse(settings.automaticMaintenance);XCTAssertFalse(settings.captureOnLaunch);XCTAssertFalse(settings.apiEnabled)
        }
    }
    func testBitmapCropUsesTopLeftPixelRows() throws {
        var bytes=[UInt8]()
        for y in 0..<10 {for _ in 0..<10 {bytes.append(contentsOf:y<5 ? [255,0,0,255]:[0,0,255,255])}}
        let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),image=try XCTUnwrap(CGImage(width:10,height:10,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:40,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let top=try SnapshotRegion(height:0.5).crop(image),read=try XCTUnwrap(CGContext(data:nil,width:10,height:5,bitsPerComponent:8,bytesPerRow:40,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        read.draw(top,in:CGRect(x:0,y:0,width:10,height:5));let pixels=try XCTUnwrap(read.data).assumingMemoryBound(to:UInt8.self)
        for index in 0..<50 {XCTAssertEqual(pixels[index*4],255);XCTAssertEqual(pixels[index*4+2],0)}
    }
    func testVersion19MigrationOnlyRaisesCompatibilityFenceAndPreservesScopeAndSources() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        var settings=AppSettings();settings.snapshotRegions.focusedWindowCrop=SnapshotRegion(x:0.5,width:0.5);try settings.save(root:root)
        let first=try MemoryStore(root:root);try first.insert(Memory(id:"owned-scope-fence",text:"Owned source remains"));try first.close()
        var database:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&database),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database,"PRAGMA user_version=19",nil,nil,nil),SQLITE_OK);sqlite3_close(database)
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()}
        XCTAssertEqual(MemoryStore.schemaVersion,21);XCTAssertEqual(try reopened.get("owned-scope-fence")?.text,"Owned source remains");XCTAssertEqual(AppSettings.load(root:root),settings)
        try reopened.withRoutineDatabase {db in
            let statement=try db.statement("PRAGMA user_version");defer {sqlite3_finalize(statement)}
            XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(statement,0),Int32(MemoryStore.schemaVersion))
        }
    }
    func testQuietRestorationPreservesScopeWithoutStartingCapture() throws {
        var original=AppSettings();original.allDisplays=true;original.captureOnLaunch=true;original.snapshotRegions.selectedDisplays=[a];original.snapshotRegions.displayCrops[a]=SnapshotRegion(x:0.5,width:0.5)
        let quiet=LibraryBackup.quietSettings(original);XCTAssertFalse(quiet.captureOnLaunch);XCTAssertEqual(quiet.snapshotRegions,original.snapshotRegions);XCTAssertTrue(quiet.allDisplays)
    }
}
