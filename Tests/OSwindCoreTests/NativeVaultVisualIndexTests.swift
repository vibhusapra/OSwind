import XCTest
@testable import OSwindCore

final class NativeVaultVisualIndexTests:XCTestCase {
    func testEncryptedVisualSnapshotsReleasePinsAndDescriptorsBeforeVerifiedDetach() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted visual fixture; no normal history or Keychain")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-visual-vault-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Visual.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned visual fixture",capacityGiB:1,passphrase:secret)
            _ = try await vault.unlock(passphrase:secret);let store=try MemoryStore(root:vault.libraryURL)
            let image=Memory(id:"image",app:"Fixture",text:"",imagePath:"images/one.dat")
            try Data("Owned synthetic image bytes".utf8).write(to:store.root.appendingPathComponent(image.imagePath!));try store.insert(image)
            var video=Memory(id:"video",app:"Fixture",text:"");video.videoPath="video/one.mov"
            video.visualRecording=VisualRecording(duration:2,width:128,height:96,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:"one"),VisualFrame(time:1,text:"two")]);video.text=video.visualRecording!.text
            try Data("Owned synthetic pin bytes; decoding covered separately".utf8).write(to:store.root.appendingPathComponent(video.videoPath!));try store.insert(video)
            let imageSnapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:image.id)),videoSnapshot=try XCTUnwrap(VisualVideoSnapshot.make(store:store,id:video.id))
            defer {imageSnapshot.release();videoSnapshot.release()}
            _ = try store.saveVisualVectors([.init(point:imageSnapshot.plan.points[0],decodedTime:nil,vector:[1,0])],snapshot:imageSnapshot,modelID:"fixture")
            _ = try store.saveVisualVectors(videoSnapshot.plan.points.map {.init(point:$0,decodedTime:$0.time,vector:[1,0])},snapshot:videoSnapshot,modelID:"fixture")
            let mount=store.root.resolvingSymlinksInPath().deletingLastPathComponent(),pin=videoSnapshot.url
            XCTAssertTrue(pin.path.contains("/video/.staging/.oswind-visual-index-"))
            let locking=Task {try await vault.lock(store:store)}
            var closing=false
            for _ in 0..<500 {
                if let session=try? JSONDecoder().decode(VaultSession.self,from:Data(contentsOf:package.appendingPathComponent("session.json"))),session.phase == .closing {closing=true;break}
                try await Task.sleep(for:.milliseconds(10))
            }
            XCTAssertTrue(closing);XCTAssertFalse(store.isClosed)
            imageSnapshot.release();videoSnapshot.release()
            let locked=try await locking.value;XCTAssertEqual(locked.state,.locked);XCTAssertTrue(store.isClosed)
            // The snapshot objects are deliberately still retained. Their root
            // descriptors/pins must not keep the encrypted backing device open.
            XCTAssertFalse(FileManager.default.fileExists(atPath:mount.path));XCTAssertFalse(FileManager.default.fileExists(atPath:pin.path))
            XCTAssertThrowsError(try imageSnapshot.validatedMemory());XCTAssertThrowsError(try videoSnapshot.withAdmission(for:store) {$0})
            let attached=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(attached)
            _ = try await vault.unlock(passphrase:secret);let reopened=try MemoryStore(root:vault.libraryURL)
            XCTAssertEqual(try reopened.visualCoverage(modelID:"fixture").indexedFrames,3)
            XCTAssertEqual(Set(try reopened.searchVisual(SearchFilter(),vector:[1,0],modelID:"fixture").hits.map(\.id)),Set(["image","video"]))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:reopened.root.appendingPathComponent("video/.staging").path).isEmpty)
            _ = try await vault.lock(store:reopened);try FileManager.default.removeItem(at:root)
        } catch {_ = try? await vault.lock();throw error}
    }
}
