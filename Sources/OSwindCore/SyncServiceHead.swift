import Foundation

/// Authenticated discovery hint, never membership, receipt or erasure authority.
/// Shared-key authentication identifies the group; it is not a device signature.
struct SyncServiceHead:Codable,Equatable,Sendable {
    let format:String
    let version:Int
    let group:String,epoch:String,replica:String
    let through:Int64,collectionCounter:Int64
    let capabilities:[String]
    static let supported=["canonical-13-v1","collection-control-v1","creation-era-v1","publication-v1","supersession-v1"]
    init(group:String,epoch:String,replica:String,through:Int64,collectionCounter:Int64)throws {
        format="OSwind.sync.head";version=1;self.group=group;self.epoch=epoch;self.replica=replica;self.through=through;self.collectionCounter=collectionCounter;capabilities=Self.supported
        try validate()
    }
    func validate()throws {
        try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch);try SyncProtocolLimits.uuid(replica)
        guard format=="OSwind.sync.head",version==1,through>=0,collectionCounter>=0,capabilities==Self.supported else {throw OSwindError.invalid("Sync peer capabilities or head differ")}
    }
    func encoded()throws->Data {try validate();return try SyncProtocolLimits.encode(self)}
    static func decode(_ data:Data)throws->Self {
        guard data.count<=4096 else {throw OSwindError.invalid("Sync head exceeds its bound")}
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate()
        guard try value.encoded()==data else {throw OSwindError.invalid("Noncanonical sync head")};return value
    }
    static func descriptor(_ replica:String)throws->Data {try SyncProtocolLimits.uuid(replica);return Data("OSwind.sync.service-head.v1\0\(replica)".utf8)}
}
