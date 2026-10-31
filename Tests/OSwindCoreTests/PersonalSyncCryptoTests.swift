import XCTest
@testable import OSwindCore

final class PersonalSyncCryptoTests:XCTestCase {
    let group="00000000-0000-0000-0000-000000000001"
    let epoch="00000000-0000-0000-0000-000000000002"
    let other="00000000-0000-0000-0000-000000000003"
    let descriptor=Data("authored source version and chunk identity".utf8)
    func context(_ key:SyncGroupSecret,group:String?=nil,epoch:String?=nil,purpose:SyncObjectPurpose = .operation)throws->SyncCipherContext {
        try .init(secret:key,group:group ?? self.group,epoch:epoch ?? self.epoch,purpose:purpose)
    }
    func changed(_ data:Data,_ body:(inout [String:Any])throws->Void)throws->Data {
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);try body(&value)
        return try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func testRoundTripEmptySmallAndFullChunkWithoutPlaintextMetadata() throws {
        let key=SyncGroupSecret(),cipher=try context(key)
        for bytes in [Data(),Data("owned secret note".utf8),Data(repeating:37,count:SyncCipherContext.maximumPlaintextBytes)] {
            let object=try cipher.seal(bytes,descriptor:descriptor)
            XCTAssertEqual(try cipher.open(object.bytes,expectedToken:object.token,descriptor:descriptor),bytes)
            let dictionary=try XCTUnwrap(JSONSerialization.jsonObject(with:object.bytes) as? [String:Any])
            XCTAssertEqual(Set(dictionary.keys),Set(["format","version","sealed"]))
            XCTAssertFalse(object.bytes.range(of:Data("owned secret note".utf8)) != nil)
        }
    }
    func testWrongKeyGroupEpochPurposeAndAddressFailAuthentication() throws {
        let key=SyncGroupSecret(),cipher=try context(key),object=try cipher.seal(Data("authored source".utf8),descriptor:descriptor)
        for wrong in [try context(SyncGroupSecret()),try context(key,group:other),try context(key,epoch:other),try context(key,purpose:.contentChunk)] {
            XCTAssertThrowsError(try wrong.open(object.bytes,expectedToken:object.token))
        }
        XCTAssertThrowsError(try cipher.open(object.bytes,expectedToken:String(repeating:"0",count:64)))
        XCTAssertThrowsError(try cipher.open(object.bytes,expectedToken:object.token,descriptor:Data("another identity".utf8)))
        XCTAssertThrowsError(try cipher.open(object.bytes,expectedToken:"../outside"))
    }
    func testNonceCiphertextAndTagChangesCannotReachPlaintext() throws {
        let cipher=try context(SyncGroupSecret()),object=try cipher.seal(Data("authored original payload".utf8),descriptor:descriptor)
        for offset in [0,12,25,50] {
            let tampered=try changed(object.bytes) {value in
                var sealed=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(value["sealed"] as? String)))
                sealed[min(offset,sealed.count-1)] ^= 1
                value["sealed"]=sealed.base64EncodedString()
            }
            XCTAssertThrowsError(try cipher.open(tampered,expectedToken:object.token))
        }
    }
    func testUnknownFormatVersionFieldsAndTruncatedBoxRefuse() throws {
        let cipher=try context(SyncGroupSecret()),object=try cipher.seal(Data("authored".utf8),descriptor:descriptor)
        let variants=[try changed(object.bytes) {$0["format"]="another format"},try changed(object.bytes) {$0["version"]=2},try changed(object.bytes) {$0["untrustedField"]="must not be accepted"},try changed(object.bytes) {$0["sealed"]=Data(repeating:0,count:27).base64EncodedString()}]
        for variant in variants {XCTAssertThrowsError(try cipher.open(variant,expectedToken:object.token))}
    }
    func testAddressesAreKeyedContextSeparatedAndRetriesUseFreshNonces() throws {
        let key=SyncGroupSecret(),cipher=try context(key)
        let address=try cipher.token(for:descriptor)
        XCTAssertEqual(address,try cipher.token(for:descriptor));XCTAssertEqual(address.utf8.count,64)
        for other in [try context(key,group:other),try context(key,epoch:other),try context(key,purpose:.checkpoint),try context(SyncGroupSecret())] {XCTAssertNotEqual(address,try other.token(for:descriptor))}
        var nonces=Set<Data>()
        // Read the actual nonce bytes; format/version fields have mixed JSON types.
        for _ in 0..<128 {
            let object=try cipher.seal(Data("same retry content".utf8),descriptor:descriptor)
            let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:object.bytes) as? [String:Any])
            let sealed=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fields["sealed"] as? String)))
            XCTAssertTrue(nonces.insert(Data(sealed.prefix(12))).inserted)
        }
    }
    func testSecretExportIsExplicitAndDescriptionsDoNotRevealKey() throws {
        let material=Data(repeating:81,count:32),key=try SyncGroupSecret(rawRepresentation:material)
        XCTAssertTrue(key.exportForPairing()==material)
        XCTAssertEqual(String(describing:key),"<redacted sync group key>")
        XCTAssertFalse(String(reflecting:key).contains(material.base64EncodedString()))
        XCTAssertEqual(Mirror(reflecting:key).children.count,1)
        XCTAssertThrowsError(try SyncGroupSecret(rawRepresentation:Data(repeating:0,count:31)))
        let exported=try context(key).seal(Data("authored paired content".utf8),descriptor:descriptor)
        let imported=try context(SyncGroupSecret(rawRepresentation:material))
        XCTAssertEqual(try imported.open(exported.bytes,expectedToken:exported.token),Data("authored paired content".utf8))
    }
    func testCipherContextDescriptionsAndReflectionExcludeDerivedKeys()throws {
        let cipher=try context(SyncGroupSecret())
        XCTAssertEqual(String(describing:cipher),"<redacted sync cipher context>")
        XCTAssertEqual(String(reflecting:cipher),"<redacted sync cipher context>")
        let children=Mirror(reflecting:cipher).children
        XCTAssertEqual(children.count,1);XCTAssertEqual(children.first?.label,"keys")
        XCTAssertEqual(children.first?.value as? String,"redacted")
    }
    func testBoundsRefuseBeforeUnboundedDecodeOrEncryption() throws {
        let cipher=try context(SyncGroupSecret())
        XCTAssertThrowsError(try cipher.seal(Data(repeating:0,count:SyncCipherContext.maximumPlaintextBytes+1),descriptor:descriptor))
        XCTAssertThrowsError(try cipher.open(Data(repeating:32,count:SyncCipherContext.maximumEnvelopeBytes+1),expectedToken:String(repeating:"0",count:64)))
        XCTAssertThrowsError(try cipher.token(for:Data()))
        XCTAssertThrowsError(try cipher.token(for:Data(repeating:0,count:SyncProtocolLimits.operationBytes+1)))
    }
}
