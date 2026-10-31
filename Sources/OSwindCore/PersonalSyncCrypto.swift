import Foundation
import CryptoKit

struct SyncGroupSecret:CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable,Sendable {
    fileprivate let key:SymmetricKey
    init() {key=SymmetricKey(size:.bits256)}
    init(rawRepresentation:Data)throws {
        guard rawRepresentation.count==32 else {throw OSwindError.invalid("Sync group key material must contain 32 bytes")}
        key=SymmetricKey(data:rawRepresentation)
    }
    // Only explicit pairing/recovery UI may call this. Never make this type
    // Codable or include it in settings, packet metadata, logs or process argv.
    func exportForPairing()->Data {key.withUnsafeBytes {Data($0)}}
    var description:String {"<redacted sync group key>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["key":"redacted"])}
}
enum SyncObjectPurpose:String,Sendable {case operation,contentChunk,checkpoint,membership}
struct SyncCipherContext:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    var description:String {"<redacted sync cipher context>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["keys":"redacted"])}
    static let maximumPlaintextBytes=1_048_576
    static let maximumEnvelopeBytes=1_402_196
    let group:String
    let epoch:String
    let purpose:SyncObjectPurpose
    private let encryptionKey:SymmetricKey
    private let addressKey:SymmetricKey
    init(secret:SyncGroupSecret,group:String,epoch:String,purpose:SyncObjectPurpose)throws {
        try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch)
        self.group=group;self.epoch=epoch;self.purpose=purpose
        let salt=Data("OSwind.sync.v1\0\(group)\0\(epoch)\0".utf8)
        encryptionKey=HKDF<SHA256>.deriveKey(inputKeyMaterial:secret.key,salt:salt,info:Data("encryption\0\(purpose.rawValue)".utf8),outputByteCount:32)
        addressKey=HKDF<SHA256>.deriveKey(inputKeyMaterial:secret.key,salt:salt,info:Data("address\0\(purpose.rawValue)".utf8),outputByteCount:32)
    }
    func token(for descriptor:Data)throws->String {
        guard !descriptor.isEmpty,descriptor.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Invalid sync object descriptor")}
        return HMAC<SHA256>.authenticationCode(for:descriptor,using:addressKey).map {String(format:"%02x",$0)}.joined()
    }
    private func associatedData(_ token:String)throws->Data {
        try SyncProtocolLimits.digest(token)
        return Data("OSwind.sync.envelope.v1\0\(group)\0\(epoch)\0\(purpose.rawValue)\0\(token)".utf8)
    }
    struct EncryptedObject:Sendable {let token:String;let bytes:Data}
    func seal(_ plaintext:Data,descriptor:Data)throws->EncryptedObject {
        guard plaintext.count<=Self.maximumPlaintextBytes else {throw OSwindError.invalid("Sync object exceeds its plaintext bound")}
        let address=try token(for:descriptor)
        let box=try AES.GCM.seal(plaintext,using:encryptionKey,authenticating:associatedData(address))
        guard let combined=box.combined else {throw OSwindError.unavailable("Cannot encode encrypted sync object")}
        let data=try SyncProtocolLimits.encode(Envelope(sealed:combined))
        guard data.count<=Self.maximumEnvelopeBytes else {throw OSwindError.invalid("Encrypted sync object exceeds its envelope bound")}
        return .init(token:address,bytes:data)
    }
    func open(_ bytes:Data,expectedToken:String,descriptor:Data?=nil)throws->Data {
        guard !bytes.isEmpty,bytes.count<=Self.maximumEnvelopeBytes else {throw OSwindError.invalid("Encrypted sync object exceeds its envelope bound")}
        do {
            let aad=try associatedData(expectedToken)
            if let descriptor {guard try token(for:descriptor)==expectedToken else {throw OSwindError.invalid("Sync object address differs")}}
            let envelope=try JSONDecoder().decode(Envelope.self,from:bytes)
            guard envelope.sealed.count>=28,envelope.sealed.count<=Self.maximumPlaintextBytes+28 else {throw OSwindError.invalid("Invalid encrypted sync object size")}
            let plaintext=try AES.GCM.open(AES.GCM.SealedBox(combined:envelope.sealed),using:encryptionKey,authenticating:aad)
            guard plaintext.count<=Self.maximumPlaintextBytes else {throw OSwindError.invalid("Sync plaintext exceeds its bound")}
            return plaintext
        } catch {throw OSwindError.invalid("Sync object could not be authenticated")}
    }
    private struct WireKey:CodingKey {
        let stringValue:String
        var intValue:Int? {nil}
        init?(stringValue:String) {self.stringValue=stringValue}
        init?(intValue:Int) {return nil}
    }
    private struct Envelope:Codable {
        let format:String
        let version:Int
        let sealed:Data
        init(sealed:Data) {format="OSwind encrypted sync object";version=1;self.sealed=sealed}
        private enum CodingKeys:String,CodingKey {case format,version,sealed}
        init(from decoder:Decoder)throws {
            let all=try decoder.container(keyedBy:WireKey.self)
            guard Set(all.allKeys.map(\.stringValue))==Set(["format","version","sealed"]) else {throw OSwindError.invalid("Unsupported sync envelope fields")}
            let c=try decoder.container(keyedBy:CodingKeys.self)
            format=try c.decode(String.self,forKey:.format);version=try c.decode(Int.self,forKey:.version);sealed=try c.decode(Data.self,forKey:.sealed)
            guard format=="OSwind encrypted sync object",version==1 else {throw OSwindError.invalid("Unsupported sync envelope")}
        }
    }
}
