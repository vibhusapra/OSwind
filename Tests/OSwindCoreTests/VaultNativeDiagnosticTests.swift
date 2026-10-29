import XCTest
@testable import OSwindCore

final class VaultNativeDiagnosticTests:XCTestCase {
    let privateOutput=Data("private fixture /owned/private-history PRIVATE-CREDENTIAL".utf8)
    func testSafeErrorDescriptionReflectionAndSummaryNeverIncludeNativeText()throws {
        for operation:VaultNativeOperation in [.attachmentInventory,.encryptionProbe,.volumeInfo,.imageDetach,.filesystemUnmount] {
            let result=VaultProcessResult(status:35,stdout:privateOutput,stderr:privateOutput),error=VaultNativeFailure(operation:operation,result:result)
            let summary=String(decoding:try JSONEncoder().encode(error.summary),as:UTF8.self)
            for text in [error.localizedDescription,String(describing:error),String(reflecting:error),summary] {
                XCTAssertFalse(text.contains("private-history"));XCTAssertFalse(text.contains("PRIVATE-CREDENTIAL"));XCTAssertFalse(text.contains("/owned"))
            }
            XCTAssertTrue(error.localizedDescription.contains("35"));XCTAssertEqual(error.summary.status,35)
            XCTAssertEqual(error.summary.stdoutSHA256,BackupSHA256.hex(privateOutput));XCTAssertEqual(error.summary.stderrBytes,privateOutput.count)
        }
    }
    func testFailureMessageDoesNotAssertThatEveryNonzeroStatusIsBusy() {
        let error=VaultNativeFailure(operation:.imageDetach,result:.init(status:72,stdout:Data(),stderr:privateOutput))
        XCTAssertTrue(error.localizedDescription.contains("If files are in use"));XCTAssertFalse(error.localizedDescription.contains("because files are in use"))
        XCTAssertTrue(error.localizedDescription.contains("Check vault status"))
    }
    func testObservationNeverExposesInventoryOrDeviceStdout() {
        for operation:VaultNativeOperation in [.attachmentInventory,.encryptionProbe,.volumeInfo] {
            let diagnostic=VaultNativeDiagnostic(operation:operation,result:.init(status:0,stdout:privateOutput,stderr:Data()))
            XCTAssertNil(diagnostic.stdoutSuffix);XCTAssertEqual(diagnostic.summary.stdoutBytes,privateOutput.count)
        }
    }
    func testExplicitOwnedMutationExcerptsAreBoundedAndKeepFullOutputHashes() {
        let data=Data(repeating:65,count:20000)
        let result=VaultProcessResult(status:16,stdout:data,stderr:data),diagnostic=VaultNativeDiagnostic(operation:.imageDetach,result:result,durationSeconds:0.25)
        XCTAssertEqual(diagnostic.stdoutSuffix?.utf8.count,4096);XCTAssertEqual(diagnostic.stderrSuffix.utf8.count,4096)
        XCTAssertEqual(diagnostic.summary.stderrBytes,20000);XCTAssertEqual(diagnostic.summary.stderrSHA256,BackupSHA256.hex(data))
        XCTAssertEqual(diagnostic.durationSeconds,0.25)
    }
    func testAttachmentInventorySeparatesNativeFailureFromMalformedSuccess()throws {
        do {_ = try NativeVaultDriver.attachmentList(.init(status:35,stdout:Data(),stderr:privateOutput));XCTFail("Native failure accepted")}
        catch let error as VaultNativeFailure {XCTAssertFalse(error.invalidOutput);XCTAssertEqual(error.summary.status,35)}
        for object:Any in ["bad",["unexpected":[]],["images":"bad"]] {
            let data=try PropertyListSerialization.data(fromPropertyList:object,format:.xml,options:0)
            do {_ = try NativeVaultDriver.attachmentList(.init(status:0,stdout:data,stderr:Data()));XCTFail("Malformed inventory accepted")}
            catch let error as VaultNativeFailure {XCTAssertTrue(error.invalidOutput);XCTAssertEqual(error.summary.status,0);XCTAssertTrue(error.localizedDescription.contains("invalid inventory"))}
        }
        XCTAssertTrue(try NativeVaultDriver.attachmentList(.init(status:0,stdout:PropertyListSerialization.data(fromPropertyList:["images":[]],format:.xml,options:0),stderr:Data())).isEmpty)
    }
    func testMalformedRawInventoryCannotEscapeThroughCocoaParserError() {
        XCTAssertThrowsError(try NativeVaultDriver.attachmentList(.init(status:0,stdout:privateOutput,stderr:Data()))) {error in
            XCTAssertTrue(error is VaultNativeFailure);XCTAssertFalse(error.localizedDescription.contains("PRIVATE-CREDENTIAL"))
        }
    }
    func testMissingEncryptionFlagIsUnknownRatherThanFalse()throws {
        for object:Any in [[String:Bool](),["encrypted":"unknown"],"bad"] {
            let data=try PropertyListSerialization.data(fromPropertyList:object,format:.xml,options:0)
            XCTAssertThrowsError(try NativeVaultDriver.encryptionFlag(.init(status:0,stdout:data,stderr:Data()))) {error in
                XCTAssertTrue((error as? VaultNativeFailure)?.invalidOutput == true)
            }
        }
    }
    func testExplicitEncryptionBooleansArePreservedAndFailureDoesNotUseBody()throws {
        for value in [true,false] {
            let data=try PropertyListSerialization.data(fromPropertyList:["encrypted":value],format:.xml,options:0)
            XCTAssertEqual(try NativeVaultDriver.encryptionFlag(.init(status:0,stdout:data,stderr:Data())),value)
            XCTAssertThrowsError(try NativeVaultDriver.encryptionFlag(.init(status:6,stdout:data,stderr:Data()))) {error in
                XCTAssertEqual((error as? VaultNativeFailure)?.summary.status,6)
            }
        }
    }
}
