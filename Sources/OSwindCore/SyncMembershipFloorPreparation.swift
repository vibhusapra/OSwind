import Foundation

/// Exact local compatibility fence for an already-cleared native36 preview.
/// It changes no signed membership, key, provider state or wire operation.
struct SyncMembershipFloorPreparation:Codable,Equatable,Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    let format:String,version:Int,operation:String
    let pairingID:String,pairingDigest:String,materialDigest:String,head:String
    let epochBefore:String,epochAfter:String
    let tokenBefore:SyncDeliveryAnchor.Token,tokenAfter:SyncDeliveryAnchor.Token
    func validate()throws {
        guard format=="OSwind.sync.membership-floor",version==1 else {throw OSwindError.invalid("Invalid saved membership floor upgrade")}
        try SyncProtocolLimits.uuid(operation);try SyncCredentialStorageLimits.validate(id:pairingID)
        for value in [pairingDigest,materialDigest,head] {try SyncProtocolLimits.digest(value)}
        for value in [epochBefore,epochAfter] {guard value.utf8.count==32,value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw OSwindError.invalid("Invalid floor writer generation")}}
        try tokenBefore.validate();try tokenAfter.validate()
        guard epochBefore != epochAfter,tokenBefore.serial<Int64.max-1,tokenAfter.serial==tokenBefore.serial+1,tokenBefore.nonce != tokenAfter.nonce else {throw OSwindError.invalid("Advance the membership floor checkpoint exactly once")}
    }
    var description:String {"<redacted membership floor upgrade>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["operation":"redacted"])}
}
