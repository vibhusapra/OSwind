import Foundation

/// A bounded pointer in the original private pairing account. The response and
/// its signed binding live in that device's encrypted local inbox, never prefs.
struct SyncOwnerApprovalReference:Codable,Equatable,Sendable {
    let content:SyncContentReference
    let requestDigest:String,head:String,pairingID:String,lifetime:String
    let approvedAt:Int64
    func validate()throws {
        guard content.bytes>0,content.bytes<=SyncOwnerApprovalPlan.maximumBytes else {throw OSwindError.invalid("Saved approval exceeds its bound")}
        try SyncProtocolLimits.digest(requestDigest);try SyncProtocolLimits.digest(head)
        try SyncCredentialStorageLimits.validate(id:pairingID);try SyncProtocolLimits.uuid(lifetime)
        guard approvedAt>=0,approvedAt<=253402300799 else {throw OSwindError.invalid("Invalid saved approval time")}
    }
}

/// The root binds opaque recipient ciphertext to the exact admitted certificate.
/// Recovery verifies the original approval instant; it never refreshes expiry.
struct SyncOwnerApprovalPlan:Codable,Equatable,Sendable {
    static let maximumBytes:Int64=327680
    enum Purpose:String,Codable,Sendable {case addition,legacyReissue}
    struct Binding:Codable,Equatable,Sendable {
        let format:String,version:Int,purpose:Purpose
        let group:String,epoch:String,pairingID:String,lifetime:String
        let requestDigest:String,predecessor:String,head:String,responseDigest:String
        let approvedAt:Int64
    }
    let format:String,version:Int
    let request:SyncJoinRequest,prior:SyncMembershipCertificate,certificate:SyncMembershipCertificate
    let response:Data,binding:Binding,signature:Data

    func validate()throws {
        guard format=="OSwind.sync.owner-approval-plan",version==1,binding.format=="OSwind.sync.owner-approval-binding",binding.version==1,
              binding.approvedAt>=0,binding.approvedAt<=253402300799,signature.count==64 else {throw OSwindError.invalid("Invalid saved owner approval")}
        try request.validate(now:Date(timeIntervalSince1970:TimeInterval(binding.approvedAt)))
        try SyncCredentialStorageLimits.validate(id:binding.pairingID);try SyncProtocolLimits.uuid(binding.lifetime)
        try prior.verify(root:certificate.body.rootPublicKey);try certificate.verify(root:certificate.body.rootPublicKey)
        switch binding.purpose {
        case .addition:
            try certificate.requireSuccessor(of:prior)
            guard !prior.body.members.contains(try SyncMember(request)) else {throw OSwindError.invalid("The reviewed request is not the newly added member")}
        case .legacyReissue:guard certificate==prior else {throw OSwindError.invalid("Response reissue cannot change membership")}
        }
        guard certificate.body.members.contains(try SyncMember(request)),binding.group==certificate.body.group,binding.epoch==certificate.body.epoch,
              binding.requestDigest == (try request.digest),binding.predecessor==SyncProtocolLimits.hex(try prior.encoded()),
              binding.head==SyncProtocolLimits.hex(try certificate.encoded()),binding.responseDigest==SyncProtocolLimits.hex(response),
              try SyncPairingFormat.signingKey(certificate.body.rootPublicKey).isValidSignature(signature,for:SyncPairingFormat.domain("owner-approval",SyncProtocolLimits.encode(binding))) else {throw OSwindError.invalid("Saved approval authority or exact response differs")}
        try SyncPairingFormat.verifyOwnerResponse(response,request:request,root:certificate.body.rootPublicKey)
    }
    func encoded()throws->Data {
        try validate();let bytes=try SyncProtocolLimits.encode(self)
        guard bytes.count<=Self.maximumBytes else {throw OSwindError.invalid("Owner approval plan exceeds its bound")};return bytes
    }
    static func decode(_ bytes:Data)throws->Self {
        let value=try SyncPairingFormat.decode(Self.self,bytes,limit:Int(maximumBytes));try value.validate();return value
    }
    func reference()throws->SyncOwnerApprovalReference {
        let value=try SyncOwnerApprovalReference(content:SyncContentReference(data:encoded()),requestDigest:binding.requestDigest,head:binding.head,pairingID:binding.pairingID,lifetime:binding.lifetime,approvedAt:binding.approvedAt)
        try value.validate();return value
    }
    func require(_ reference:SyncOwnerApprovalReference,current:SyncMembershipCertificate,pairingID:String,lifetime:String)throws {
        try reference.validate();try validate();try current.verify(root:certificate.body.rootPublicKey)
        guard try self.reference()==reference,reference.pairingID==pairingID,reference.lifetime==lifetime,
              current.body.group==binding.group,current.body.epoch==binding.epoch else {throw OSwindError.invalid("Saved response belongs to another pairing lifetime")}
    }
}
