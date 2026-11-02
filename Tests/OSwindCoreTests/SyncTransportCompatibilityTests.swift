import XCTest
@testable import OSwindCore

extension PersonalSyncFolderTests {
    func testTransportV2RefusesAuthenticatedLegacyV1SpaceWithoutChangingIt()throws {
        let legacy=root.appendingPathComponent("legacy-v1");try Paths.ensure(legacy)
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.checkpoint)
        let marker=try cipher.seal(Data("OSwind encrypted object space v1".utf8),descriptor:Data("OSwind.sync.space-marker.v1".utf8))
        let tree=try BackupFileTree(root:legacy,writable:true);try tree.write(marker.bytes,as:"space-v1")
        XCTAssertThrowsError(try SyncObjectFolder.open(at:legacy,secret:secret,group:group,epoch:epoch),"A legacy marker does not promise erasure or supersession support")
        XCTAssertEqual(try tree.read("space-v1",limit:SyncCipherContext.maximumEnvelopeBytes),marker.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:legacy.path),["space-v1"],"Opening must not silently migrate a legacy peer's space")
    }
    func testTransportV2DoesNotProvideTheMarkerRequiredByThePriorV1Reader()throws {
        let tree=try BackupFileTree(root:space)
        // These are the exact filename and authenticated descriptor used by
        // the prior transport. This is a marker-boundary check, not a claim
        // that the frozen old application completed a wire exchange.
        XCTAssertThrowsError(try tree.read("space-v1",limit:SyncCipherContext.maximumEnvelopeBytes))
        let bytes=try tree.read("space-v2",limit:SyncCipherContext.maximumEnvelopeBytes)
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.checkpoint)
        let descriptor=Data("OSwind.sync.space-marker.v2".utf8),token=try cipher.token(for:descriptor)
        XCTAssertEqual(try cipher.open(bytes,expectedToken:token,descriptor:descriptor),Data("OSwind encrypted object space v2; creation-era-v1; collection-control-v1; supersession-v1".utf8))
        let oldDescriptor=Data("OSwind.sync.space-marker.v1".utf8),oldToken=try cipher.token(for:oldDescriptor)
        XCTAssertThrowsError(try cipher.open(bytes,expectedToken:oldToken,descriptor:oldDescriptor))
    }
}
