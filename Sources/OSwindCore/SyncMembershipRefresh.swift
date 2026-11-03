import Foundation

/// Public, root-signed addition history. This proves a contiguous successor
/// path; it does not enroll a native writer, update Keychain, rotate a group
/// secret, revoke a device, or establish global provider freshness.
struct SyncMembershipRefresh:Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    static let maximumBytes=98_304
    private struct Payload:Codable,Sendable {
        let format:String,version:Int
        let base:SyncMembershipCertificate
        let updates:[SyncMembershipCertificate]
    }
    private let payload:Payload
    var base:SyncMembershipCertificate {payload.base}
    var head:SyncMembershipCertificate {payload.updates.last!}
    var updateCount:Int {payload.updates.count}

    init(base:SyncMembershipCertificate,updates:[SyncMembershipCertificate])throws {
        try Self.verify(base:base,updates:updates)
        payload = .init(format:"OSwind.sync.membership-refresh",version:1,base:base,updates:updates)
        guard try encoded().count<=Self.maximumBytes else {throw OSwindError.invalid("Membership history exceeds one update page")}
    }
    private init(verified payload:Payload) {self.payload=payload}
    private static func verify(base:SyncMembershipCertificate,updates:[SyncMembershipCertificate])throws {
        guard !updates.isEmpty,updates.count<SyncProtocolLimits.peers else {throw OSwindError.invalid("Use a bounded nonempty membership history")}
        try base.verify(root:base.body.rootPublicKey)
        var prior=base
        for next in updates {try next.requireSuccessor(of:prior);prior=next}
    }
    /// The caller retains its complete authenticated history and sends further
    /// pages after this head. Validate the entire supplied path before selecting
    /// a prefix, so a late fork/corruption is never hidden by a byte boundary.
    static func boundedPrefix(base:SyncMembershipCertificate,updates:[SyncMembershipCertificate])throws->Self {
        try verify(base:base,updates:updates)
        var accepted=[SyncMembershipCertificate](),result:Payload?
        for next in updates {
            let candidate=Payload(format:"OSwind.sync.membership-refresh",version:1,base:base,updates:accepted+[next])
            guard try SyncProtocolLimits.encode(candidate).count<=maximumBytes else {break}
            accepted.append(next)
            result=candidate
        }
        guard let result else {throw OSwindError.invalid("A membership step cannot fit the update bound")}
        return .init(verified:result)
    }
    func encoded()throws->Data {try SyncProtocolLimits.encode(payload)}
    static func decode(_ bytes:Data)throws->Self {
        let payload=try SyncPairingFormat.decode(Payload.self,bytes,limit:maximumBytes)
        guard payload.format=="OSwind.sync.membership-refresh",payload.version==1 else {throw OSwindError.invalid("Unsupported membership update")}
        return try .init(base:payload.base,updates:payload.updates)
    }
    /// Exact overlap supports retries and an already-applied prefix. A signed
    /// fork with the same revision is insufficient: the current certificate
    /// itself must occur on this verified path. Older-only pages refuse.
    func advance(from trusted:SyncMembershipCertificate)throws->SyncMembershipCertificate {
        try trusted.verify(root:trusted.body.rootPublicKey)
        guard base.body.rootPublicKey==trusted.body.rootPublicKey,
              base.body.group==trusted.body.group,base.body.epoch==trusted.body.epoch else {throw OSwindError.invalid("Membership update belongs to another group or epoch")}
        try Self.verify(base:base,updates:payload.updates)
        guard ([base]+payload.updates).contains(trusted) else {throw OSwindError.invalid("Membership update does not extend the exact trusted history")}
        return head
    }
    var description:String {"<redacted membership refresh>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["membership":"redacted"])}
}
