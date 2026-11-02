import Foundation

/// Body-free group erasure, separate from the thirteen portable native kinds.
/// A native wipe only captures intent. The owning sender additionally requires
/// a durable explicit group-review decision before publishing this frame.
struct SyncCollectionControl:Codable,Equatable,Sendable {
    let format:String
    let version:Int
    let purpose:String
    let group:String,epoch:String,creator:String
    let counter:Int64
    let era:SyncClock
    init(group:String,epoch:String,creator:String,counter:Int64,era:SyncClock)throws {
        try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch);try SyncProtocolLimits.uuid(creator)
        guard counter>0,era[creator]==counter else {throw OSwindError.invalid("Collection control differs from its captured wipe counter")}
        format="OSwind.sync.collection-control";version=1;purpose="group-erasure"
        self.group=group;self.epoch=epoch;self.creator=creator;self.counter=counter;self.era=era
    }
    private enum CodingKeys:String,CodingKey {case format,version,purpose,group,epoch,creator,counter,era}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard try c.decode(String.self,forKey:.format)=="OSwind.sync.collection-control",try c.decode(Int.self,forKey:.version)==1,try c.decode(String.self,forKey:.purpose)=="group-erasure" else {throw OSwindError.invalid("Only explicit group-erasure controls may cross a peer boundary")}
        try self.init(group:c.decode(String.self,forKey:.group),epoch:c.decode(String.self,forKey:.epoch),creator:c.decode(String.self,forKey:.creator),counter:c.decode(Int64.self,forKey:.counter),era:c.decode(SyncClock.self,forKey:.era))
    }
    func encoded()throws->Data {
        let bytes=try SyncProtocolLimits.encode(self)
        guard bytes.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Collection control exceeds its bound")};return bytes
    }
    static func decode(_ bytes:Data)throws->Self {
        guard !bytes.isEmpty,bytes.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Collection control exceeds its bound")}
        let value=try JSONDecoder().decode(Self.self,from:bytes)
        guard try value.encoded()==bytes else {throw OSwindError.invalid("Collection control is not canonical")};return value
    }
    var digest:String {get throws {try SyncProtocolLimits.hex(encoded())}}
    static func descriptor(creator:String,counter:Int64)throws->Data {
        _=try SyncDot(replica:creator,counter:counter)
        return Data("OSwind.sync.collection-control.v1\0\(creator)\0\(counter)".utf8)
    }
    func erases(_ revision:SyncRevision)->Bool {
        revision.mutation == .put && (revision.creationEra ?? .empty)[creator]<counter
    }
}

enum SyncCollectionReview:Equatable {
    case ready
    case needsGroupReview(SyncCollectionControl)
}
