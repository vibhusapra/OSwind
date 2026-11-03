import Foundation

/// The response plan belongs to the pairing lifetime; completed delivery also
/// belongs to a particular publication lifetime. These are separate authorities.
struct SyncDeliveryApprovalReference:Codable,Equatable,Sendable {
    let approval:SyncOwnerApprovalReference
    let publicationLifetime:String
    func validate()throws {
        try approval.validate()
        let uuid=UUID(uuidString:publicationLifetime)?.uuidString.lowercased()==publicationLifetime
        let hex=publicationLifetime.utf8.count==32 && publicationLifetime.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})
        guard uuid || hex else {throw OSwindError.invalid("Invalid approval publication lifetime")}
    }
    func require(pairingID:String,head:String,publicationLifetime:String?)throws {
        try validate()
        guard approval.pairingID==pairingID,approval.head==head,self.publicationLifetime==publicationLifetime else {throw OSwindError.invalid("Saved approval differs from its membership or publication lifetime")}
    }
}
