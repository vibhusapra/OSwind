import Foundation

/// An immutable replacement permits cursor progress without retransmitting a
/// pruned private body. It never authorizes projecting that obsolete body.
struct SyncSupersessionProof:Codable,Equatable,Sendable {
    let format:String
    let version:Int
    let obsolete:SyncDot,successor:SyncDot
    let obsoleteDigest:String,successorDigest:String
    let successorRevision:SyncRevision
    init(obsolete:SyncRevision,successor:SyncRevision)throws {
        try Self.validate(obsolete:obsolete,successor:successor)
        format="OSwind.sync.supersession";version=1;self.obsolete=obsolete.dot;self.successor=successor.dot
        obsoleteDigest=try SyncProtocolLimits.hex(obsolete.encoded());successorDigest=try SyncProtocolLimits.hex(successor.encoded());successorRevision=successor
    }
    static func validate(obsolete:SyncRevision,successor:SyncRevision)throws {
        guard obsolete.mutation == .put,successor.mutation == .put,obsolete.key==successor.key,successor.context.contains(obsolete.dot),(obsolete.creationEra ?? .empty)==(successor.creationEra ?? .empty) else {throw OSwindError.invalid("Supersession requires a causal replacement of the same immutable lifetime")}
    }
    static func descriptor(_ dot:SyncDot)->Data {Data("OSwind.sync.supersession.v1\0\(dot.replica)\0\(dot.counter)".utf8)}
    func encoded()throws->Data {let data=try SyncProtocolLimits.encode(self);guard data.count<=SyncProtocolLimits.operationBytes+4096 else {throw OSwindError.invalid("Supersession proof exceeds its bound")};return data}
    static func decode(_ data:Data)throws->Self {
        guard !data.isEmpty,data.count<=SyncProtocolLimits.operationBytes+4096 else {throw OSwindError.invalid("Supersession proof exceeds its bound")}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.format=="OSwind.sync.supersession",value.version==1,value.successorRevision.dot==value.successor,try value.successorDigest==SyncProtocolLimits.hex(value.successorRevision.encoded()),try value.encoded()==data else {throw OSwindError.invalid("Invalid supersession proof")}
        try SyncProtocolLimits.digest(value.obsoleteDigest);try SyncProtocolLimits.digest(value.successorDigest);return value
    }
    func matches(obsolete:SyncRevision,successor:SyncRevision)throws->Bool {
        try Self.validate(obsolete:obsolete,successor:successor)
        return try self.obsolete==obsolete.dot && self.successor==successor.dot && obsoleteDigest==SyncProtocolLimits.hex(obsolete.encoded()) && successorDigest==SyncProtocolLimits.hex(successor.encoded())
    }
}
