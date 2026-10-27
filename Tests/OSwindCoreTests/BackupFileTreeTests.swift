import XCTest
import CryptoKit
import Darwin
@testable import OSwindCore

final class BackupFileTreeTests: XCTestCase {
    var root: URL!, sourceURL: URL!, targetURL: URL!, source: BackupFileTree!, target: BackupFileTree!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sourceURL = root.appendingPathComponent("source"); targetURL = root.appendingPathComponent("target")
        try Paths.ensure(sourceURL); try Paths.ensure(targetURL)
        source = try BackupFileTree(root:sourceURL); target = try BackupFileTree(root:targetURL,writable:true)
    }
    override func tearDownWithError() throws { source = nil; target = nil; try? FileManager.default.removeItem(at:root) }
    @discardableResult func fixture(_ name: String = "images/a.jpg", data: Data = Data("Synthetic media bytes".utf8)) throws -> URL {
        let url = sourceURL.appendingPathComponent(name); try Paths.ensure(url.deletingLastPathComponent()); try data.write(to:url); return url
    }
    func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    func testStreamingCopyHashAndBoundedMetadataRead() throws {
        let data = Data(repeating:0xa5,count:3*1024*1024+17); try fixture(data:data)
        var events = [Int64]()
        let result = try source.copy("images/a.jpg",to:target,as:"media/blob") { events.append($0) }
        XCTAssertEqual(result,BackupFileDigest(bytes:Int64(data.count),sha256:sha(data)))
        XCTAssertGreaterThan(events.count,1); XCTAssertEqual(events.last,Int64(data.count))
        XCTAssertEqual(try target.digest("media/blob"),result)
        XCTAssertThrowsError(try target.read("media/blob",limit:128))
        XCTAssertEqual(try target.read("media/blob",limit:data.count),data)
        let mode = try FileManager.default.attributesOfItem(atPath:targetURL.appendingPathComponent("media/blob").path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777,0o600)
    }
    func testBoundedDigestKnownHashesExactAndEmptyBoundsAndNoProgressOnOversize() throws {
        try fixture("abc",data:Data("abc".utf8));try fixture("empty",data:Data())
        XCTAssertEqual(try source.digest("abc",limit:3),BackupFileDigest(bytes:3,sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        XCTAssertEqual(try source.digest("empty",limit:0),BackupFileDigest(bytes:0,sha256:"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
        var reads=0
        XCTAssertThrowsError(try source.digest("abc",limit:2) {_ in reads+=1})
        XCTAssertThrowsError(try source.digest("abc",limit:0) {_ in reads+=1})
        XCTAssertThrowsError(try source.digest("abc",limit:-1) {_ in reads+=1})
        XCTAssertEqual(reads,0)
        XCTAssertEqual(try source.digest("abc",limit:Int64.max).sha256,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testBoundedDigestRetainsCancellationAndMutationChecks() throws {
        let data=Data(repeating:0x77,count:3*1024*1024),url=try fixture("large",data:data)
        var callbacks=0
        do { _ = try source.digest("large",limit:Int64(data.count)) {_ in callbacks+=1;throw CancellationError()};XCTFail("Cancellation swallowed") }
        catch is CancellationError {} catch {XCTFail("Wrong cancellation error: \(error)")}
        XCTAssertEqual(callbacks,1)
        var changed=false
        XCTAssertThrowsError(try source.digest("large",limit:Int64(data.count)) {_ in
            if !changed {changed=true;let file=try FileHandle(forWritingTo:url);try file.truncate(atOffset:1);try file.close()}
        })
        XCTAssertTrue(changed)
        XCTAssertEqual(try source.digest("large",limit:1),BackupFileDigest(bytes:1,sha256:sha(Data([0x77]))))
    }
    func testBoundedDigestRejectsLinksAndSpecialFilesWithoutFollowingOrBlocking() throws {
        let outside=root.appendingPathComponent("owned-outside"),data=Data("Owned outside sentinel".utf8)
        try data.write(to:outside)
        try FileManager.default.createSymbolicLink(at:sourceURL.appendingPathComponent("link"),withDestinationURL:outside)
        let fifo=sourceURL.appendingPathComponent("fifo");XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        for name in ["link","fifo","../owned-outside"] {XCTAssertThrowsError(try source.digest(name,limit:100))}
        XCTAssertEqual(try Data(contentsOf:outside),data)
    }
    func testTraversalNULAndOversizedComponentsCannotReadOrWrite() throws {
        try fixture()
        let invalid = ["","/etc/passwd","../outside","images/../a.jpg","images//a.jpg","images/./a.jpg","images/a.jpg/","images/a\0.jpg",String(repeating:"x/",count:65)+"f","images/"+String(repeating:"x",count:256)]
        for path in invalid {
            XCTAssertThrowsError(try source.read(path,limit:100),path)
            XCTAssertThrowsError(try target.write(Data("bad".utf8),as:path),path)
        }
        XCTAssertEqual(try source.read("images/a.jpg",limit:100),Data("Synthetic media bytes".utf8))
    }
    func testSymlinkComponentsAndFinalLinksCannotEscapeEitherTree() throws {
        let outside = root.appendingPathComponent("outside"); try Paths.ensure(outside); let secret = outside.appendingPathComponent("keep"); try Data("Keep outside unchanged".utf8).write(to:secret)
        try FileManager.default.createSymbolicLink(at:sourceURL.appendingPathComponent("escape"),withDestinationURL:outside)
        try FileManager.default.createSymbolicLink(at:sourceURL.appendingPathComponent("link"),withDestinationURL:secret)
        try FileManager.default.createSymbolicLink(at:targetURL.appendingPathComponent("escape"),withDestinationURL:outside)
        try FileManager.default.createSymbolicLink(at:targetURL.appendingPathComponent("link"),withDestinationURL:secret)
        XCTAssertThrowsError(try source.digest("escape/keep")); XCTAssertThrowsError(try source.digest("link"))
        XCTAssertThrowsError(try target.write(Data("bad".utf8),as:"escape/new")); XCTAssertThrowsError(try target.write(Data("bad".utf8),as:"link"))
        XCTAssertEqual(try Data(contentsOf:secret),Data("Keep outside unchanged".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath:outside.appendingPathComponent("new").path))
    }
    func testReadOnlyTreesAndExistingFilesCannotBeOverwritten() throws {
        try fixture(); XCTAssertThrowsError(try source.write(Data(),as:"new"))
        try target.write(Data("original".utf8),as:"member")
        XCTAssertThrowsError(try source.copy("images/a.jpg",to:target,as:"member"))
        XCTAssertEqual(try target.read("member",limit:100),Data("original".utf8))
        XCTAssertThrowsError(try source.pin("images/a.jpg",to:target,as:"member"))
        XCTAssertEqual(try target.read("member",limit:100),Data("original".utf8))
    }
    func testSpecialFileIsRejectedWithoutBlocking() throws {
        let fifo = sourceURL.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try source.read("fifo",limit:100)); XCTAssertThrowsError(try source.pin("fifo",to:target,as:"pin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:targetURL.appendingPathComponent("pin").path))
    }
    func testCancellationAndMutationRemoveOnlyThePartialOutput() throws {
        let data = Data(repeating:0x77,count:3*1024*1024), url = try fixture(data:data)
        XCTAssertThrowsError(try source.copy("images/a.jpg",to:target,as:"cancelled") { _ in throw CancellationError() })
        XCTAssertFalse(FileManager.default.fileExists(atPath:targetURL.appendingPathComponent("cancelled").path))
        var changed = false
        XCTAssertThrowsError(try source.copy("images/a.jpg",to:target,as:"mutated") { _ in
            if !changed { changed = true; let file = try FileHandle(forWritingTo:url); try file.truncate(atOffset:1); try file.close() }
        })
        XCTAssertTrue(changed); XCTAssertFalse(FileManager.default.fileExists(atPath:targetURL.appendingPathComponent("mutated").path))
    }
    func testAlreadyOpenedFileSurvivesSourceDeletionDuringCopy() throws {
        let data = Data(repeating:0x66,count:2*1024*1024+9), url = try fixture(data:data); var deleted = false
        let result = try source.copy("images/a.jpg",to:target,as:"survived") { _ in
            if !deleted { deleted = true; try FileManager.default.removeItem(at:url) }
        }
        XCTAssertTrue(deleted); XCTAssertEqual(result.sha256,sha(data)); XCTAssertEqual(try target.read("survived",limit:data.count),data)
    }
    func testCloneAndStreamingPinsHaveIndependentContent() throws {
        let data = Data(repeating:0x44,count:1024*1024+3), url = try fixture(data:data)
        let method = try source.pin("images/a.jpg",to:target,as:"clone-or-copy")
        print("Backup pin method: \(method.rawValue)")
        XCTAssertEqual(try source.pin("images/a.jpg",to:target,as:"stream-copy",preferClone:false),.copy)
        let file = try FileHandle(forWritingTo:url); try file.truncate(atOffset:1); try file.close(); try FileManager.default.removeItem(at:url)
        XCTAssertEqual(try target.digest("clone-or-copy"),BackupFileDigest(bytes:Int64(data.count),sha256:sha(data)))
        XCTAssertEqual(try target.digest("stream-copy"),try target.digest("clone-or-copy"))
    }
    func testRetainedRootDescriptorIgnoresPathReplacement() throws {
        try fixture(data:Data("original namespace".utf8))
        try FileManager.default.moveItem(at:sourceURL,to:root.appendingPathComponent("moved-source"))
        try fixture(data:Data("replacement namespace".utf8))
        XCTAssertEqual(try source.read("images/a.jpg",limit:100),Data("original namespace".utf8))
    }
    func testRootMustBeRealAndWritableWorkspaceMustBePrivate() throws {
        let link = root.appendingPathComponent("root-link"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:sourceURL)
        XCTAssertThrowsError(try BackupFileTree(root:link))
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:targetURL.path)
        XCTAssertThrowsError(try BackupFileTree(root:targetURL,writable:true))
        XCTAssertNoThrow(try BackupFileTree(root:targetURL))
    }
    func testEmptyAndUnicodeNamedFilesRemainExact() throws {
        try fixture("images/é 🪁.jpg",data:Data())
        XCTAssertEqual(try source.copy("images/é 🪁.jpg",to:target,as:"media/empty"),BackupFileDigest(bytes:0,sha256:sha(Data())))
        XCTAssertEqual(try target.read("media/empty",limit:0),Data())
        XCTAssertThrowsError(try target.read("missing",limit:10))
    }
}

extension BackupFileTreeTests {
    func testStreamingMemberWriterAndDirectoryEnumeration() throws {
        try target.withNewFile("media/manifest") { descriptor in
            let file = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
            for i in 0..<100 { try file.write(contentsOf:Data("line-\(i)\n".utf8)) }
        }
        var names = [String](); try target.forEachEntry(in:"media") { names.append($0) }
        XCTAssertEqual(names,["manifest"])
        XCTAssertEqual(String(data:try target.read("media/manifest",limit:10000),encoding:.utf8)?.split(separator:"\n").count,100)
        XCTAssertThrowsError(try target.withNewFile("media/partial") { _ in throw CancellationError() } as Void)
        var rootNames = [String](); try target.forEachEntry { rootNames.append($0) }; XCTAssertEqual(rootNames,["media"])
        var repeated = [String](); try target.forEachEntry { repeated.append($0) }; XCTAssertEqual(repeated,rootNames)
        var nestedNames = [String](); try target.forEachEntry(in:"media") { nestedNames.append($0) }; XCTAssertEqual(nestedNames,["manifest"])
        XCTAssertThrowsError(try target.forEachEntry(in:"../outside") { _ in })
    }
}

extension BackupFileTreeTests {
    func testMacUnicodeFilenameCanExceed255UTF8Bytes() throws {
        let relative = "images/"+String(repeating:"界",count:100)+".jpg", data = Data("Unicode filename fixture".utf8)
        try fixture(relative,data:data)
        XCTAssertEqual(try source.read(relative,limit:100),data)
        XCTAssertEqual(try source.copy(relative,to:target,as:"media/opaque"),BackupFileDigest(bytes:Int64(data.count),sha256:sha(data)))
    }
}
