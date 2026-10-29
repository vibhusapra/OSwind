import XCTest
import Darwin
@testable import OSwindCore

final class VaultQueryDriverTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-query-driver-"+UUID().uuidString)
        try Paths.ensure(root)
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    private func paths() throws -> VaultPaths {
        let package=root.appendingPathComponent("Owned.oswindvault");try Paths.ensure(package)
        let paths=try VaultPaths(package)
        try paths.write(LibraryVaultInfo(name:"Owned query fixture",capacityGiB:1,volumeUUID:UUID().uuidString),as:VaultPaths.manifestName)
        try Paths.ensure(paths.image)
        return paths
    }
    private actor Transport {
        let signal:Bool
        var calls=0
        init(signal:Bool) {self.signal=signal}
        func query(_ operation:VaultNativeOperation,_ executable:String,_ arguments:[String],_ timeout:Double) async throws -> VaultProcessResult {
            calls+=1
            XCTAssertEqual(operation,.attachmentInventory);XCTAssertEqual(executable,"/usr/bin/hdiutil");XCTAssertEqual(arguments,["info","-plist"])
            if calls==1 {
                // Real process classification, not an inferred numeric status.
                // This is a Python control, not an interrupted native hdiutil.
                let code=signal ? "import os,signal;signal.signal(signal.SIGINT,signal.SIG_DFL);os.kill(os.getpid(),signal.SIGINT)":"raise SystemExit(2)"
                return try await VaultProcess.run("/usr/bin/python3",["-c",code],timeout:timeout)
            }
            return .init(status:0,stdout:try PropertyListSerialization.data(fromPropertyList:["images":[]],format:.xml,options:0),stderr:Data())
        }
    }
    func testInterruptedInventoryCanBeObservedAgainAfterARealSIGINTControl() async throws {
        let paths=try paths(),transport=Transport(signal:true)
        let driver=NativeVaultDriver(queryProcess:{try await transport.query($0,$1,$2,$3)})
        let proof=try await driver.attachment(paths:paths)
        XCTAssertNil(proof)
        let calls=await transport.calls;XCTAssertEqual(calls,2)
    }
    func testNormalExitTwoRemainsAnInventoryFailureWithoutAnotherQuery() async throws {
        let paths=try paths(),transport=Transport(signal:false)
        let driver=NativeVaultDriver(queryProcess:{try await transport.query($0,$1,$2,$3)})
        do {_ = try await driver.attachment(paths:paths);XCTFail("Normal native failure was retried")}
        catch let failure as VaultNativeFailure {XCTAssertEqual(failure.summary.termination,.exit);XCTAssertEqual(failure.summary.status,2)}
        let calls=await transport.calls;XCTAssertEqual(calls,1)
    }
    func testSuccessfulInventoryCannotAdmitAbsenceAfterImageReplacement() async throws {
        let paths=try paths()
        let driver=NativeVaultDriver(queryProcess:{operation,_,_,_ in
            XCTAssertEqual(operation,.attachmentInventory)
            try FileManager.default.moveItem(at:paths.image,to:paths.package.appendingPathComponent("preserved-image"));try Paths.ensure(paths.image)
            return .init(status:0,stdout:try PropertyListSerialization.data(fromPropertyList:["images":[]],format:.xml,options:0),stderr:Data())
        })
        do {_ = try await driver.attachment(paths:paths);XCTFail("Stale empty inventory admitted a replaced image")}
        catch {XCTAssertTrue(error.localizedDescription.contains("identity changed"))}
    }
}
