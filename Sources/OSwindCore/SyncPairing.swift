import Foundation
import CryptoKit

// Internal pairing protocol. A certificate does not enroll the native library
// or enable the legacy shared-key transport. Signed transport, durable Keychain
// binding, rollback protection and reviewed UI remain separate admission gates.
enum SyncPairingFormat {
    static let capabilities=(SyncServiceHead.supported+["device-signature-v1","root-membership-v1"]).sorted()
    static let requestLimit=8192,certificateLimit=65536,responseLimit=98304
    static func domain(_ name:String,_ body:Data)->Data {Data("OSwind.sync.pairing.v1\0\(name)\0".utf8)+body}
    static func decode<T:Codable>(_ type:T.Type,_ bytes:Data,limit:Int)throws->T {
        guard !bytes.isEmpty,bytes.count<=limit else {throw OSwindError.invalid("Pairing message exceeds its bound")}
        let value=try JSONDecoder().decode(type,from:bytes)
        guard try SyncProtocolLimits.encode(value)==bytes else {throw OSwindError.invalid("Pairing message is not canonical")}
        return value
    }
    static func seconds(_ now:Date)throws->Int64 {
        let value=now.timeIntervalSince1970
        guard value.isFinite,value>=0,value<=253402300799 else {throw OSwindError.invalid("Invalid pairing time")}
        return Int64(value)
    }
    static func name(_ value:String)throws {
        guard !value.isEmpty,value.utf8.count<=80,value==value.trimmingCharacters(in:.whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0) && !CharacterSet(charactersIn:"\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)}) else {throw OSwindError.invalid("Use a short device name without control characters")}
    }
    static func signingKey(_ bytes:Data)throws->Curve25519.Signing.PublicKey {
        guard bytes.count==32 else {throw OSwindError.invalid("Invalid device signing key")}
        return try .init(rawRepresentation:bytes)
    }
    static func agreementKey(_ bytes:Data)throws->Curve25519.KeyAgreement.PublicKey {
        guard bytes.count==32 else {throw OSwindError.invalid("Invalid device agreement key")}
        return try .init(rawRepresentation:bytes)
    }
    static func fingerprint(_ bytes:Data)throws->String {_=try signingKey(bytes);return SyncProtocolLimits.hex(domain("root-fingerprint",bytes))}
}

/// Private device keys are generated on the joining Mac. Only the signed public
/// request leaves it. Never make this type Codable or place it in preferences.
struct SyncDeviceKeys:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    fileprivate let signing:Curve25519.Signing.PrivateKey
    fileprivate let agreement:Curve25519.KeyAgreement.PrivateKey
    init() {signing = .init();agreement = .init()}
    fileprivate init(signing:Data,agreement:Data)throws {
        guard signing.count==32,agreement.count==32 else {throw OSwindError.invalid("Invalid saved sync device keys")}
        self.signing=try .init(rawRepresentation:signing);self.agreement=try .init(rawRepresentation:agreement)
    }
    var description:String {"<redacted sync device keys>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["keys":"redacted"])}
}

struct SyncJoinRequest:Codable,Equatable,Sendable {
    struct Body:Codable,Equatable,Sendable {
        let format:String,version:Int,request:String,replica:String,name:String
        let signingPublicKey:Data,agreementPublicKey:Data
        let capabilities:[String]
        let created:Int64,expires:Int64
    }
    let body:Body,signature:Data
    init(keys:SyncDeviceKeys,name:String,now:Date=Date())throws {
        let created=try SyncPairingFormat.seconds(now)
        body = .init(format:"OSwind.sync.join-request",version:1,request:UUID().uuidString.lowercased(),replica:UUID().uuidString.lowercased(),name:name,signingPublicKey:keys.signing.publicKey.rawRepresentation,agreementPublicKey:keys.agreement.publicKey.rawRepresentation,capabilities:SyncPairingFormat.capabilities,created:created,expires:created+600)
        signature=try keys.signing.signature(for:SyncPairingFormat.domain("join-request",SyncProtocolLimits.encode(body)))
        try validate(now:now)
    }
    func validate(now:Date)throws {
        let current=try SyncPairingFormat.seconds(now)
        guard body.format=="OSwind.sync.join-request",body.version==1,body.capabilities==SyncPairingFormat.capabilities,
              body.created>=0,body.created<=253402300799,body.expires>body.created,body.expires-body.created<=600,
              body.created<=current+60,current<=body.expires,signature.count==64 else {throw OSwindError.invalid("Pairing request is expired or incompatible")}
        try SyncProtocolLimits.uuid(body.request);try SyncProtocolLimits.uuid(body.replica);try SyncPairingFormat.name(body.name)
        _=try SyncPairingFormat.agreementKey(body.agreementPublicKey)
        guard try SyncPairingFormat.signingKey(body.signingPublicKey).isValidSignature(signature,for:SyncPairingFormat.domain("join-request",SyncProtocolLimits.encode(body))) else {throw OSwindError.invalid("Pairing request signature differs")}
    }
    func encoded()throws->Data {
        let bytes=try SyncProtocolLimits.encode(self)
        guard bytes.count<=SyncPairingFormat.requestLimit else {throw OSwindError.invalid("Pairing request exceeds its bound")};return bytes
    }
    static func decode(_ bytes:Data,now:Date=Date())throws->Self {
        let value=try SyncPairingFormat.decode(Self.self,bytes,limit:SyncPairingFormat.requestLimit);try value.validate(now:now);return value
    }
    var digest:String {get throws {SyncProtocolLimits.hex(try encoded())}}
}

struct SyncMember:Codable,Equatable,Sendable {
    let replica:String,name:String,signingPublicKey:Data,agreementPublicKey:Data,requestDigest:String
    init(_ request:SyncJoinRequest)throws {
        replica=request.body.replica;name=request.body.name;signingPublicKey=request.body.signingPublicKey
        agreementPublicKey=request.body.agreementPublicKey;requestDigest=try request.digest
    }
    func validate()throws {
        try SyncProtocolLimits.uuid(replica);try SyncPairingFormat.name(name);try SyncProtocolLimits.digest(requestDigest)
        _=try SyncPairingFormat.signingKey(signingPublicKey);_=try SyncPairingFormat.agreementKey(agreementPublicKey)
        guard signingPublicKey != agreementPublicKey else {throw OSwindError.invalid("Use separate device keys")}
    }
}

/// A root signature proves membership and its exact capability floor. A group
/// encryption key is deliberately insufficient to issue or edit certificates.
/// This first format admits additions only; it does not claim revocation.
struct SyncMembershipCertificate:Codable,Equatable,Sendable {
    struct Body:Codable,Equatable,Sendable {
        let format:String,version:Int,group:String,epoch:String,revision:Int64,previous:String?
        let rootPublicKey:Data,owner:String,capabilities:[String],members:[SyncMember]
    }
    let body:Body,signature:Data
    fileprivate init(body:Body,root:Curve25519.Signing.PrivateKey)throws {
        self.body=body;signature=try root.signature(for:SyncPairingFormat.domain("membership",SyncProtocolLimits.encode(body)))
        try verify(root:root.publicKey.rawRepresentation)
    }
    func verify(root:Data)throws {
        guard body.format=="OSwind.sync.membership",body.version==1,body.rootPublicKey==root,
              body.capabilities==SyncPairingFormat.capabilities,body.revision>0,
              (body.revision==1)==(body.previous==nil),!body.members.isEmpty,body.members.count<=SyncProtocolLimits.peers,
              body.members.map(\.replica)==body.members.map(\.replica).sorted(),signature.count==64 else {throw OSwindError.invalid("Membership authority or capabilities differ")}
        try SyncProtocolLimits.uuid(body.group);try SyncProtocolLimits.uuid(body.epoch);try SyncProtocolLimits.uuid(body.owner)
        if let previous=body.previous {try SyncProtocolLimits.digest(previous)}
        for member in body.members {try member.validate()}
        guard Set(body.members.map(\.replica)).count==body.members.count,
              Set(body.members.map(\.signingPublicKey)).count==body.members.count,
              Set(body.members.map(\.agreementPublicKey)).count==body.members.count,
              Set(body.members.map(\.requestDigest)).count==body.members.count,
              body.members.contains(where:{$0.replica==body.owner}),
              try SyncPairingFormat.signingKey(root).isValidSignature(signature,for:SyncPairingFormat.domain("membership",SyncProtocolLimits.encode(body))) else {throw OSwindError.invalid("Membership signature or device identities differ")}
        guard try encoded().count<=SyncPairingFormat.certificateLimit else {throw OSwindError.invalid("Membership exceeds its bound")}
    }
    func requireSuccessor(of prior:Self)throws {
        try prior.verify(root:prior.body.rootPublicKey);try verify(root:prior.body.rootPublicKey)
        guard prior.body.revision<Int64.max,body.revision==prior.body.revision+1,body.previous==SyncProtocolLimits.hex(try prior.encoded()),
              body.group==prior.body.group,body.epoch==prior.body.epoch,body.owner==prior.body.owner,
              body.members.count==prior.body.members.count+1,prior.body.members.allSatisfy({body.members.contains($0)}) else {throw OSwindError.invalid("Membership does not extend the trusted addition history")}
    }
    func encoded()throws->Data {try SyncProtocolLimits.encode(self)}
    static func decode(_ bytes:Data,root:Data)throws->Self {
        let value=try SyncPairingFormat.decode(Self.self,bytes,limit:SyncPairingFormat.certificateLimit);try value.verify(root:root);return value
    }
}

struct SyncGroupAuthority:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    private let root:Curve25519.Signing.PrivateKey
    fileprivate let secret:SyncGroupSecret
    let certificate:SyncMembershipCertificate
    init(owner:SyncJoinRequest,now:Date=Date())throws {
        try owner.validate(now:now);let root=Curve25519.Signing.PrivateKey();self.root=root;secret=SyncGroupSecret()
        certificate=try .init(body:.init(format:"OSwind.sync.membership",version:1,group:UUID().uuidString.lowercased(),epoch:UUID().uuidString.lowercased(),revision:1,previous:nil,rootPublicKey:root.publicKey.rawRepresentation,owner:owner.body.replica,capabilities:SyncPairingFormat.capabilities,members:[SyncMember(owner)]),root:root)
    }
    private init(root:Curve25519.Signing.PrivateKey,secret:SyncGroupSecret,certificate:SyncMembershipCertificate) {self.root=root;self.secret=secret;self.certificate=certificate}
    fileprivate var rootForKeychain:Data {root.rawRepresentation}
    fileprivate static func restore(root:Data,secret:SyncGroupSecret,certificate:SyncMembershipCertificate)throws->Self {
        guard root.count==32 else {throw OSwindError.invalid("Invalid saved sync owner key")}
        let signing=try Curve25519.Signing.PrivateKey(rawRepresentation:root)
        try certificate.verify(root:signing.publicKey.rawRepresentation)
        return .init(root:signing,secret:secret,certificate:certificate)
    }
    var fingerprint:String {get throws {try SyncPairingFormat.fingerprint(root.publicKey.rawRepresentation)}}
    func admitting(_ request:SyncJoinRequest,now:Date=Date())throws->Self {
        try request.validate(now:now);try certificate.verify(root:root.publicKey.rawRepresentation)
        let member=try SyncMember(request)
        if certificate.body.members.contains(member) {return self}
        guard certificate.body.members.count<SyncProtocolLimits.peers,certificate.body.revision<Int64.max else {throw OSwindError.invalid("Membership is full")}
        let next=try SyncMembershipCertificate(body:.init(format:certificate.body.format,version:1,group:certificate.body.group,epoch:certificate.body.epoch,revision:certificate.body.revision+1,previous:SyncProtocolLimits.hex(certificate.encoded()),rootPublicKey:certificate.body.rootPublicKey,owner:certificate.body.owner,capabilities:SyncPairingFormat.capabilities,members:(certificate.body.members+[member]).sorted {$0.replica<$1.replica}),root:root)
        try next.requireSuccessor(of:certificate)
        return .init(root:root,secret:secret,certificate:next)
    }
    func response(to request:SyncJoinRequest,now:Date=Date())throws->Data {
        try request.validate(now:now)
        guard certificate.body.members.contains(try SyncMember(request)) else {throw OSwindError.invalid("Review and admit the exact device request before pairing")}
        let ephemeral=Curve25519.KeyAgreement.PrivateKey(),rootPublic=root.publicKey.rawRepresentation,requestDigest=try request.digest
        let context=SyncPairingResponse.Context(format:"OSwind.sync.join-response",version:1,requestDigest:requestDigest,rootPublicKey:rootPublic,ephemeralPublicKey:ephemeral.publicKey.rawRepresentation)
        let key=try SyncPairingResponse.key(shared:ephemeral.sharedSecretFromKeyAgreement(with:SyncPairingFormat.agreementKey(request.body.agreementPublicKey)),context:context,recipient:request.body.agreementPublicKey)
        let payload=SyncPairingResponse.Payload(groupSecret:secret.exportForPairing(),certificate:certificate)
        let box=try AES.GCM.seal(SyncProtocolLimits.encode(payload),using:key,authenticating:SyncProtocolLimits.encode(context))
        guard let sealed=box.combined else {throw OSwindError.unavailable("Cannot seal pairing response")}
        let body=SyncPairingResponse.Body(context:context,sealed:sealed)
        let response=SyncPairingResponse(body:body,signature:try root.signature(for:SyncPairingFormat.domain("join-response",SyncProtocolLimits.encode(body))))
        let encoded=try SyncProtocolLimits.encode(response)
        guard encoded.count<=SyncPairingFormat.responseLimit else {throw OSwindError.invalid("Pairing response exceeds its bound")};return encoded
    }
    var description:String {"<redacted sync group authority>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["authority":"redacted"])}
}

private struct SyncPairingResponse:Codable {
    struct Context:Codable {let format:String,version:Int,requestDigest:String,rootPublicKey:Data,ephemeralPublicKey:Data}
    struct Body:Codable {let context:Context,sealed:Data}
    struct Payload:Codable {let groupSecret:Data,certificate:SyncMembershipCertificate}
    let body:Body,signature:Data
    static func key(shared:SharedSecret,context:Context,recipient:Data)throws->SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data(context.requestDigest.utf8),sharedInfo:SyncPairingFormat.domain("join-response-key",try SyncProtocolLimits.encode(context))+recipient,outputByteCount:32)
    }
}

struct SyncPendingJoin:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    private let keys:SyncDeviceKeys
    let request:SyncJoinRequest
    init(name:String,now:Date=Date())throws {let keys=SyncDeviceKeys();self.keys=keys;request=try .init(keys:keys,name:name,now:now)}
    /// The fingerprint must come from the already trusted Mac's review screen,
    /// not from this untrusted response. No trust-on-first-use fallback exists.
    func accept(_ bytes:Data,expectedRootFingerprint:String,now:Date=Date())throws->SyncJoinedGroup {
        do {
            try request.validate(now:now);try SyncProtocolLimits.digest(expectedRootFingerprint)
            let value=try SyncPairingFormat.decode(SyncPairingResponse.self,bytes,limit:SyncPairingFormat.responseLimit),context=value.body.context
            guard context.format=="OSwind.sync.join-response",context.version==1,context.requestDigest == (try request.digest),
                  try SyncPairingFormat.fingerprint(context.rootPublicKey)==expectedRootFingerprint,value.signature.count==64,
                  value.body.sealed.count>=28,value.body.sealed.count<=SyncPairingFormat.certificateLimit+4096,
                  try SyncPairingFormat.signingKey(context.rootPublicKey).isValidSignature(value.signature,for:SyncPairingFormat.domain("join-response",SyncProtocolLimits.encode(value.body))) else {throw OSwindError.invalid("Pairing response authority differs")}
            let shared=try keys.agreement.sharedSecretFromKeyAgreement(with:SyncPairingFormat.agreementKey(context.ephemeralPublicKey))
            let key=try SyncPairingResponse.key(shared:shared,context:context,recipient:keys.agreement.publicKey.rawRepresentation)
            let plaintext=try AES.GCM.open(AES.GCM.SealedBox(combined:value.body.sealed),using:key,authenticating:SyncProtocolLimits.encode(context))
            let payload=try SyncPairingFormat.decode(SyncPairingResponse.Payload.self,plaintext,limit:SyncPairingFormat.certificateLimit+4096)
            try payload.certificate.verify(root:context.rootPublicKey)
            guard payload.certificate.body.members.contains(try SyncMember(request)) else {throw OSwindError.invalid("Pairing response omitted the joining device")}
            return .init(keys:keys,secret:try SyncGroupSecret(rawRepresentation:payload.groupSecret),certificate:payload.certificate,replica:request.body.replica)
        }catch {throw OSwindError.invalid("Pairing response could not be verified. Check the trusted Mac fingerprint and request expiry.")}
    }
    var description:String {"<redacted pending sync join>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["keys":"redacted"])}
}

struct SyncJoinedGroup:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    fileprivate let keys:SyncDeviceKeys,secret:SyncGroupSecret
    let certificate:SyncMembershipCertificate,replica:String
    func packetAuthority()throws->SyncDevicePacketAuthority {try .init(keys:keys,certificate:certificate,replica:replica)}
    func createTransport(at root:URL)throws->SyncObjectFolder {try .create(at:root,secret:secret,group:certificate.body.group,epoch:certificate.body.epoch,authority:packetAuthority())}
    func openTransport(at root:URL)throws->SyncObjectFolder {try .open(at:root,secret:secret,group:certificate.body.group,epoch:certificate.body.epoch,authority:packetAuthority())}
    func createPrivateInbox(at root:URL)throws->SyncObjectFolder {try .create(at:root,secret:secret,group:certificate.body.group,epoch:certificate.body.epoch)}
    func openPrivateInbox(at root:URL)throws->SyncObjectFolder {try .open(at:root,secret:secret,group:certificate.body.group,epoch:certificate.body.epoch)}
    var description:String {"<redacted joined sync group>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["keys":"redacted"])}
}

/// The only private-key serialization boundary. The app receives neither this
/// type nor its bytes. A decoded Keychain value still needs native-library and
/// installation binding, writer admission and publication-ceiling validation.
struct SyncCredentialMaterial:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    let joined:SyncJoinedGroup,owner:SyncGroupAuthority?
    private struct Payload:Codable {
        let format:String,version:Int,replica:String
        let signingPrivate:Data,agreementPrivate:Data,groupSecret:Data,ownerPrivate:Data?
        let certificate:SyncMembershipCertificate
    }
    init(joined:SyncJoinedGroup,owner:SyncGroupAuthority?=nil)throws {
        _=try joined.packetAuthority()
        if let owner {
            guard owner.certificate==joined.certificate,joined.replica==owner.certificate.body.owner,
                  owner.secret.exportForPairing()==joined.secret.exportForPairing() else {throw OSwindError.invalid("Owner authority differs from the enrolled device")}
        }
        self.joined=joined;self.owner=owner
    }
    func encodedForKeychain()throws->Data {
        let value=Payload(format:"OSwind.sync.private-material",version:1,replica:joined.replica,signingPrivate:joined.keys.signing.rawRepresentation,agreementPrivate:joined.keys.agreement.rawRepresentation,groupSecret:joined.secret.exportForPairing(),ownerPrivate:owner?.rootForKeychain,certificate:joined.certificate)
        let bytes=try SyncProtocolLimits.encode(value)
        guard bytes.count<=SyncCredentialStorageLimits.maximumBytes else {throw OSwindError.invalid("Saved sync credential exceeds its bound")};return bytes
    }
    static func decodeFromKeychain(_ bytes:Data)throws->Self {
        do {
            let value=try SyncPairingFormat.decode(Payload.self,bytes,limit:SyncCredentialStorageLimits.maximumBytes)
            guard value.format=="OSwind.sync.private-material",value.version==1 else {throw OSwindError.invalid("Saved sync material is incompatible")}
            let keys=try SyncDeviceKeys(signing:value.signingPrivate,agreement:value.agreementPrivate),secret=try SyncGroupSecret(rawRepresentation:value.groupSecret)
            let joined=SyncJoinedGroup(keys:keys,secret:secret,certificate:value.certificate,replica:value.replica)
            let owner=try value.ownerPrivate.map {try SyncGroupAuthority.restore(root:$0,secret:secret,certificate:value.certificate)}
            return try .init(joined:joined,owner:owner)
        }catch {throw OSwindError.invalid("The saved sync credential could not be verified")}
    }
    var description:String {"<redacted saved sync material>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["keys":"redacted"])}
}

/// Authorship is independent of group AEAD. A member can sign only its own
/// packets. Verification binds the device, group, epoch, purpose and opaque
/// descriptor; an encrypted packet cannot be moved to another protocol slot.
struct SyncDevicePacketAuthority:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    let certificate:SyncMembershipCertificate,replica:String
    private let keys:SyncDeviceKeys
    fileprivate init(keys:SyncDeviceKeys,certificate:SyncMembershipCertificate,replica:String)throws {
        try certificate.verify(root:certificate.body.rootPublicKey)
        guard certificate.body.members.contains(where:{$0.replica==replica && $0.signingPublicKey==keys.signing.publicKey.rawRepresentation && $0.agreementPublicKey==keys.agreement.publicKey.rawRepresentation}) else {throw OSwindError.invalid("Device keys are absent from trusted membership")}
        self.keys=keys;self.certificate=certificate;self.replica=replica
    }
    private struct Body:Codable {
        let format:String,version:Int,group:String,epoch:String,replica:String,purpose:String,descriptorDigest:String,payload:Data
    }
    private struct Packet:Codable {let body:Body,signature:Data}
    private static let payloadLimit=SyncProtocolLimits.operationBytes+4096,packetLimit=98304
    private func require(purpose:SyncObjectPurpose,descriptor:Data)throws {
        guard [.operation,.checkpoint,.collectionControl,.supersession].contains(purpose),!descriptor.isEmpty,descriptor.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Unsupported signed sync object")}
    }
    func seal(_ payload:Data,purpose:SyncObjectPurpose,descriptor:Data,replica:String)throws->Data {
        try require(purpose:purpose,descriptor:descriptor)
        guard replica==self.replica,payload.count<=Self.payloadLimit else {throw OSwindError.invalid("Cannot sign for another sync device or oversized object")}
        let body=Body(format:"OSwind.sync.device-packet",version:1,group:certificate.body.group,epoch:certificate.body.epoch,replica:replica,purpose:purpose.rawValue,descriptorDigest:SyncProtocolLimits.hex(descriptor),payload:payload)
        let packet=Packet(body:body,signature:try keys.signing.signature(for:SyncPairingFormat.domain("device-packet",SyncProtocolLimits.encode(body))))
        let bytes=try SyncProtocolLimits.encode(packet)
        guard bytes.count<=Self.packetLimit else {throw OSwindError.invalid("Signed sync object exceeds its bound")};return bytes
    }
    func open(_ bytes:Data,purpose:SyncObjectPurpose,descriptor:Data,replica:String)throws->Data {
        try require(purpose:purpose,descriptor:descriptor)
        let packet=try SyncPairingFormat.decode(Packet.self,bytes,limit:Self.packetLimit),body=packet.body
        guard body.format=="OSwind.sync.device-packet",body.version==1,body.group==certificate.body.group,body.epoch==certificate.body.epoch,
              body.replica==replica,body.purpose==purpose.rawValue,body.descriptorDigest==SyncProtocolLimits.hex(descriptor),body.payload.count<=Self.payloadLimit,packet.signature.count==64,
              let member=certificate.body.members.first(where:{$0.replica==replica}),
              try SyncPairingFormat.signingKey(member.signingPublicKey).isValidSignature(packet.signature,for:SyncPairingFormat.domain("device-packet",SyncProtocolLimits.encode(body))) else {throw OSwindError.invalid("Sync device signature or authority differs")}
        return body.payload
    }
    var description:String {"<redacted sync packet authority>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["keys":"redacted"])}
}
