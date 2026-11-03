import Foundation

/// A public certificate lookup, never authority to enroll a device or write a
/// native library. The requesting Mac retains all its private material.
struct SyncMembershipUpdateRequest:Codable,Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    static let maximumBytes=SyncPairingFormat.certificateLimit+1024
    let format:String,version:Int,certificate:SyncMembershipCertificate
    init(certificate:SyncMembershipCertificate)throws {
        try certificate.verify(root:certificate.body.rootPublicKey)
        format="OSwind.sync.membership-request";version=1;self.certificate=certificate
        guard try encoded().count<=Self.maximumBytes else {throw OSwindError.invalid("Membership request exceeds its bound")}
    }
    func encoded()throws->Data {try SyncProtocolLimits.encode(self)}
    static func decode(_ bytes:Data)throws->Self {
        let value=try SyncPairingFormat.decode(Self.self,bytes,limit:maximumBytes)
        guard value.format=="OSwind.sync.membership-request",value.version==1 else {throw OSwindError.invalid("Unsupported membership request")}
        try value.certificate.verify(root:value.certificate.body.rootPublicKey)
        return value
    }
    var description:String {"<public membership request>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["membership":"public certificate"])}
}

extension PersonalSyncPairing {
    public static var maximumMembershipRequestBytes:Int {SyncMembershipUpdateRequest.maximumBytes}
    public static var maximumMembershipUpdateBytes:Int {SyncMembershipRefresh.maximumBytes}
    /// Copy only the exact current root-signed public certificate. This neither
    /// changes local membership nor starts a provider connection.
    public func membershipUpdateRequest()throws->String {
        String(decoding:try SyncMembershipUpdateRequest(certificate:membershipCertificateForRefresh()).encoded(),as:UTF8.self)
    }
    /// Return one bounded contiguous signed page, or nil for the exact current
    /// head. A page does not establish global provider freshness. Ask again from
    /// the peer's newly committed head when further pages are needed.
    public func membershipUpdatePage(for request:String)throws->String? {
        let request=try SyncMembershipUpdateRequest.decode(Data(request.utf8))
        guard let page=try membershipRefresh(after:request.certificate) else {return nil}
        return String(decoding:try page.encoded(),as:UTF8.self)
    }
}

/// One exact session's latest reviewed public history page. No private keys or
/// pairing envelopes are exposed to presentation. Reviews are not transportable.
public struct PersonalSyncMembershipReview:Equatable,Sendable {
    public let rootFingerprint:String,updateFingerprint:String
    public let currentRevision:Int64,updatedRevision:Int64
    public let currentMemberCount:Int,updatedMemberCount:Int
    public let addedDeviceNames:[String]
    let session:UUID,token:UUID
    let workspace:PersonalSyncOwnerWorkspaceIdentity
    public func validateReopenedStore(_ store:MemoryStore)throws {try workspace.validate(store)}
}

/// The retained close/retry operation supports both owner additions and peer
/// updates. Existing owner-addition callers keep their source compatibility.
public typealias PersonalSyncMembershipChange = PersonalSyncOwnerChange
