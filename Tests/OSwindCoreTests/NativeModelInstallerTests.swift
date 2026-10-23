import XCTest
import CryptoKit
import Darwin
@testable import OSwindCore

final class NativeModelInstallerTests:XCTestCase {
    var root:URL!,manifest:NativeModelManifest!
    let body=Data("synthetic public weights".utf8)
    struct Transport:NativeModelTransport {
        let action:@Sendable (URL,Int32,Int64,@escaping @Sendable (Int64)->Void) async throws -> Void
        func download(_ url:URL,to descriptor:Int32,expectedBytes:Int64,progress:@escaping @Sendable (Int64)->Void) async throws { try await action(url,descriptor,expectedBytes,progress) }
    }
    final class Recorder:@unchecked Sendable {
        let lock=NSLock();private var calls=0;private var values=[NativeModelProgress]()
        func add(){lock.lock();calls += 1;lock.unlock()}
        var count:Int {lock.lock();defer{lock.unlock()};return calls}
        func progress(_ value:NativeModelProgress){lock.lock();values.append(value);lock.unlock()}
        var progressValues:[NativeModelProgress]{lock.lock();defer{lock.unlock()};return values}
    }
    actor Gate {
        let entered=XCTestExpectation(description:"download suspended");var continuation:CheckedContinuation<Void,Never>?
        func wait() async {await withCheckedContinuation{continuation=$0;entered.fulfill()}}
        func open(){continuation?.resume();continuation=nil}
    }
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-install-"+UUID().uuidString);try Paths.ensure(root)
        manifest=NativeModelManifest(id:"parakeet-v3-coreml",publisher:"Synthetic publisher",repository:"synthetic/public",revision:String(repeating:"a",count:40),license:"test",licenseURL:"https://example.invalid/license",attribution:"Synthetic test weights",files:[.init(path:"Model.mlmodelc/weights.bin",bytes:Int64(body.count),sha256:SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined())])
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    var destination:URL {root.appendingPathComponent("parakeet-v3-"+String(repeating:"a",count:12))}
    func transport(_ recorder:Recorder=Recorder()) -> Transport {let body=body;return Transport {url,fd,expected,progress in recorder.add();XCTAssertEqual(url.scheme,"https");XCTAssertTrue(url.path.contains(String(repeating:"a",count:40)));XCTAssertEqual(expected,Int64(body.count));let count=body.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,$0.count)};XCTAssertEqual(count,body.count);progress(Int64(count))}}
    func testPrivateAtomicInstallAndOfflineVerifiedReuse() async throws {
        let recorder=Recorder(),transfer=transport(recorder)
        let result=try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:transfer,progress:{recorder.progress($0)})
        XCTAssertFalse(result.reused);XCTAssertEqual(recorder.count,1);XCTAssertEqual(try Data(contentsOf:result.directory.appendingPathComponent("Model.mlmodelc/weights.bin")),body)
        for path in ["Model.mlmodelc/weights.bin","OSWIND-MODEL.json","ATTRIBUTION.txt"] {XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:destination.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber)?.intValue,0o600)}
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        let reused=try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,verifyOnly:true,transport:transfer)
        XCTAssertTrue(reused.reused);XCTAssertEqual(recorder.count,1)
        let progress=recorder.progressValues.map(\.completedBytes);XCTAssertEqual(progress,progress.sorted())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy{!$0.hasPrefix(".oswind-")})
    }
    func testVerificationMissingNeverCreatesCacheOrUsesNetwork() async throws {
        let recorder=Recorder(),cache=root.appendingPathComponent("missing")
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:cache,verifyOnly:true,transport:transport(recorder));XCTFail("Missing model accepted")}catch{}
        XCTAssertEqual(recorder.count,0);XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path))
    }
    func testCorruptExistingAndExtraComponentsAreNeverReplaced() async throws {
        _ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:transport())
        let file=destination.appendingPathComponent("Model.mlmodelc/weights.bin");try Data("changed".utf8).write(to:file)
        let recorder=Recorder()
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:transport(recorder));XCTFail("Corrupt model accepted")}catch{}
        XCTAssertEqual(recorder.count,0);XCTAssertEqual(try Data(contentsOf:file),Data("changed".utf8))
        try body.write(to:file);try Paths.ensure(destination.appendingPathComponent("OptionalUnverified.mlmodelc"))
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:transport(recorder));XCTFail("Unverified optional component accepted")}catch{}
        XCTAssertTrue(FileManager.default.fileExists(atPath:destination.appendingPathComponent("OptionalUnverified.mlmodelc").path))
    }
    func testFailureAndCancellationRemoveOnlyOwnedStages() async throws {
        let outside=root.appendingPathComponent("keep");try body.write(to:outside)
        let failed=Transport {_,fd,_,_ in _ = Darwin.write(fd,"bad",3);throw POSIXError(.ENOSPC)}
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:failed);XCTFail("Failed download accepted")}catch{}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["keep"])
        let gate=Gate(),body=body
        let paused=Transport {_,fd,_,_ in await gate.wait();_ = body.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,$0.count)}}
        let task=Task {try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:paused)}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();await gate.open()
        do {_ = try await task.value;XCTFail("Cancelled download accepted")}catch is CancellationError{}catch{throw error}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["keep"]);XCTAssertEqual(try Data(contentsOf:outside),body)
    }
    func testChecksumMismatchAndConcurrentDestinationRefusePublication() async throws {
        var bad=manifest!;bad.files[0].sha256=String(repeating:"0",count:64)
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:bad,cache:root,transport:transport());XCTFail("Bad digest accepted")}catch{}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        let body=body,destination=destination
        let race=Transport {_,fd,_,_ in try Paths.ensure(destination);try Data("preserve".utf8).write(to:destination.appendingPathComponent("other-job"));_ = body.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,$0.count)}}
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:race);XCTFail("Concurrent destination overwritten")}catch{}
        XCTAssertEqual(try String(contentsOf:destination.appendingPathComponent("other-job"),encoding:.utf8),"preserve")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[destination.lastPathComponent])
    }
    func testFinalAndMemberSymlinksRefusedButTrustedCacheAliasWorks() async throws {
        let alias=root.appendingPathComponent("alias"),cache=root.appendingPathComponent("cache");try Paths.ensure(cache);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:cache)
        let result=try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:alias,transport:transport())
        let member=result.directory.appendingPathComponent("Model.mlmodelc/weights.bin"),outside=root.appendingPathComponent("outside");try body.write(to:outside);try FileManager.default.removeItem(at:member);try FileManager.default.createSymbolicLink(at:member,withDestinationURL:outside)
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:alias,transport:transport());XCTFail("Linked member accepted")}catch{}
        let target=root.appendingPathComponent(destination.lastPathComponent);try FileManager.default.createSymbolicLink(at:target,withDestinationURL:result.directory)
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:root,transport:transport());XCTFail("Linked final directory accepted")}catch{}
        XCTAssertEqual(try Data(contentsOf:outside),body)
    }
    func testRootMoveOrAliasRedirectionDuringDownloadCannotPublish() async throws {
        let original=root.appendingPathComponent("cache"),moved=root.appendingPathComponent("moved"),body=body;try Paths.ensure(original)
        let transfer=Transport {_,fd,_,_ in try FileManager.default.moveItem(at:original,to:moved);try Paths.ensure(original);_ = body.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,$0.count)}}
        do {_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:original,transport:transfer);XCTFail("Moved cache accepted")}catch{}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:original.path).isEmpty);XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:moved.path).isEmpty)
    }
    func testMemoryAndBackupLocationsAreRefusedWithoutDownloadOrModification() async throws {
        let library=root.appendingPathComponent("library"),archive=root.appendingPathComponent("archive"),recorder=Recorder()
        _ = try MemoryStore(root:library);try Paths.ensure(archive)
        try Data(#"{"format":"OSwind library backup"}"#.utf8).write(to:archive.appendingPathComponent("header.json"))
        for parent in [library,archive] {
            let cache=parent.appendingPathComponent("models")
            do{_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:cache,transport:transport(recorder));XCTFail("Protected location modified")}catch{}
            XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path))
        }
        XCTAssertEqual(recorder.count,0)
    }
    func testAliasRedirectionDuringDownloadCannotPublish() async throws {
        let first=root.appendingPathComponent("first"),second=root.appendingPathComponent("second"),alias=root.appendingPathComponent("alias"),body=body
        try Paths.ensure(first);try Paths.ensure(second);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:first)
        let transfer=Transport{_,fd,_,_ in try FileManager.default.removeItem(at:alias);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:second);_ = body.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,$0.count)}}
        do{_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:alias,transport:transfer);XCTFail("Redirected alias published")}catch{}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:first.path).isEmpty);XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:second.path).isEmpty)
    }
    func testInstalledModelPackagesCannotBeUsedAsCacheParents() async throws {
        let parent=root.appendingPathComponent("existing-model");try Paths.ensure(parent)
        try Data("preserve".utf8).write(to:parent.appendingPathComponent("OSWIND-MODEL.json"))
        let recorder=Recorder(),cache=parent.appendingPathComponent("nested")
        do{_ = try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:cache,transport:transport(recorder));XCTFail("Installed package modified")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path));XCTAssertEqual(recorder.count,0)
    }
    func testAlreadyCancelledCallerCannotCreateCacheOrStartNetwork() async throws {
        let gate=Gate(),recorder=Recorder(),cache=root.appendingPathComponent("not-created"),manifest=manifest!,transfer=transport(recorder)
        let task=Task {await gate.wait();return try await NativeModelInstaller.run(.parakeet,manifest:manifest,cache:cache,transport:transfer)}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();await gate.open()
        do{_ = try await task.value;XCTFail("Already cancelled caller installed a model")}catch is CancellationError{}catch{throw error}
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path));XCTAssertEqual(recorder.count,0)
    }
    func testCatalogValidationAndEmbeddedCatalogSizes() throws {
        for kind in NativeModelKind.allCases {let value=try kind.catalog();XCTAssertEqual(value.id,kind.manifestID);XCTAssertFalse(value.files.isEmpty)}
        XCTAssertEqual(try NativeModelKind.parakeet.catalog().bytes,483106120);XCTAssertEqual(try NativeModelKind.speakers.catalog().bytes,21816863)
        for path in ["../escape","/absolute","a//b","a/./b","a/../b","a\\b","OSWIND-MODEL.json"] {var value=manifest!;value.files[0].path=path;XCTAssertThrowsError(try value.validate())}
        var value=manifest!;value.files.append(value.files[0]);XCTAssertThrowsError(try value.validate())
        value=manifest!;value.files.append(.init(path:"model.mlmodelc/WEIGHTS.BIN",bytes:1,sha256:String(repeating:"0",count:64)));XCTAssertThrowsError(try value.validate())
        value=manifest!;value.files.append(.init(path:"model.mlmodelc",bytes:1,sha256:String(repeating:"0",count:64)));XCTAssertThrowsError(try value.validate())
    }
}
