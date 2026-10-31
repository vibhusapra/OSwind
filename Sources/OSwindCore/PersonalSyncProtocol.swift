import Foundation
import CryptoKit

// Internal until durable journaling, every typed-state adapter, transport and UI
// have been qualified. These values do not enable sync or open a listener.
enum SyncProtocolLimits {
    static let peers = 64
    static let operationBytes = 65536
    static let stateBytes = 1_048_576
    static let contentBytes: Int64 = 128*1024*1024
    static func uuid(_ value:String) throws {
        guard let parsed=UUID(uuidString:value),parsed.uuidString.lowercased()==value else {throw OSwindError.invalid("Invalid sync identity")}
    }
    static func digest(_ value:String) throws {
        guard value.utf8.count==64,value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw OSwindError.invalid("Invalid sync digest")}
    }
    static func hex(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    static func encode<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
struct SyncDot:Codable,Hashable,Sendable {
    let replica:String
    let counter:Int64
    init(replica:String,counter:Int64)throws {
        try SyncProtocolLimits.uuid(replica)
        guard counter>0 else {throw OSwindError.invalid("Invalid sync sequence")}
        self.replica=replica;self.counter=counter
    }
    private enum CodingKeys:String,CodingKey {case replica,counter}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(replica:c.decode(String.self,forKey:.replica),counter:c.decode(Int64.self,forKey:.counter))
    }
}
enum SyncClockRelation:Equatable {case before,after,equal,concurrent}
struct SyncClock:Codable,Equatable,Sendable {
    private(set) var counters:[String:Int64]
    static let empty=SyncClock(validated:[:])
    private init(validated:[String:Int64]) {counters=validated}
    init(_ values:[String:Int64])throws {
        guard values.count<=SyncProtocolLimits.peers else {throw OSwindError.invalid("Sync peer clock exceeds its bound")}
        for (replica,counter) in values {try SyncProtocolLimits.uuid(replica);guard counter>0 else {throw OSwindError.invalid("Invalid sync clock")}}
        counters=values
    }
    init(from decoder:Decoder)throws {let c=try decoder.singleValueContainer();try self.init(c.decode([String:Int64].self))}
    func encode(to encoder:Encoder)throws {var c=encoder.singleValueContainer();try c.encode(counters)}
    subscript(_ replica:String)->Int64 {counters[replica] ?? 0}
    func contains(_ dot:SyncDot)->Bool {self[dot.replica]>=dot.counter}
    func covers(_ other:Self)->Bool {other.counters.allSatisfy {self[$0.key]>=$0.value}}
    func relation(to other:Self)->SyncClockRelation {
        switch (covers(other),other.covers(self)) {case(true,true):return .equal;case(true,false):return .after;case(false,true):return .before;default:return .concurrent}
    }
    func merged(with other:Self)throws->Self {
        var result=counters
        for (replica,counter) in other.counters {result[replica]=max(result[replica] ?? 0,counter)}
        return try Self(result)
    }
    func observing(_ dot:SyncDot)throws->Self {try merged(with:Self([dot.replica:dot.counter]))}
}
enum SyncObjectKind:String,Codable,CaseIterable,Sendable {
    case source,conversation,turn,conversationCitation,recapCitation,routine,routineRun,entity,entityAlias,entityMention,entityRejection,projectRejection,evidencePin
}
struct SyncObjectKey:Codable,Hashable,Sendable {
    let kind:SyncObjectKind
    let digest:String
    init(kind:SyncObjectKind,digest:String)throws {try SyncProtocolLimits.digest(digest);self.kind=kind;self.digest=digest}
    // Typed adapters include the library origin and complete primary key in this
    // byte identity. Hash bytes, not Swift String equality (which normalizes
    // Unicode): two distinct SQLite text keys must not silently become one.
    static func make(kind:SyncObjectKind,identity:Data)throws->Self {
        guard !identity.isEmpty,identity.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Invalid sync object identity size")}
        var bytes=Data("OSwind.sync.object.v1\0\(kind.rawValue)\0".utf8);bytes.append(identity)
        return try Self(kind:kind,digest:SyncProtocolLimits.hex(bytes))
    }
    private enum CodingKeys:String,CodingKey {case kind,digest}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(kind:c.decode(SyncObjectKind.self,forKey:.kind),digest:c.decode(String.self,forKey:.digest))
    }
}
struct SyncContentReference:Codable,Equatable,Sendable {
    let sha256:String
    let bytes:Int64
    init(sha256:String,bytes:Int64)throws {
        try SyncProtocolLimits.digest(sha256)
        guard bytes>=0,bytes<=SyncProtocolLimits.contentBytes else {throw OSwindError.invalid("Sync record content exceeds its bound")}
        self.sha256=sha256;self.bytes=bytes
    }
    init(data:Data)throws {
        guard data.count<=SyncProtocolLimits.contentBytes else {throw OSwindError.invalid("Sync record content exceeds its bound")}
        try self.init(sha256:SyncProtocolLimits.hex(data),bytes:Int64(data.count))
    }
    func matches(_ data:Data)->Bool {Int64(data.count)==bytes && SyncProtocolLimits.hex(data)==sha256}
    private enum CodingKeys:String,CodingKey {case sha256,bytes}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(sha256:c.decode(String.self,forKey:.sha256),bytes:c.decode(Int64.self,forKey:.bytes))
    }
}
enum SyncMutation:String,Codable,Sendable {case put,delete}
struct SyncRevision:Codable,Equatable,Sendable {
    let key:SyncObjectKey
    let dot:SyncDot
    let context:SyncClock
    let mutation:SyncMutation
    let content:SyncContentReference?
    var clock:SyncClock {get throws {try context.observing(dot)}}
    init(key:SyncObjectKey,dot:SyncDot,context:SyncClock,mutation:SyncMutation,content:SyncContentReference?=nil)throws {
        guard dot.counter>context[dot.replica],(mutation == .put)==(content != nil) else {throw OSwindError.invalid("Invalid sync revision context or content")}
        _=try context.observing(dot)
        self.key=key;self.dot=dot;self.context=context;self.mutation=mutation;self.content=content
    }
    private enum CodingKeys:String,CodingKey {case key,dot,context,mutation,content}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(key:c.decode(SyncObjectKey.self,forKey:.key),dot:c.decode(SyncDot.self,forKey:.dot),context:c.decode(SyncClock.self,forKey:.context),mutation:c.decode(SyncMutation.self,forKey:.mutation),content:c.decodeIfPresent(SyncContentReference.self,forKey:.content))
    }
    func encoded()throws->Data {let data=try SyncProtocolLimits.encode(self);guard data.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Sync operation exceeds its bound")};return data}
    static func decode(_ data:Data)throws->Self {
        guard !data.isEmpty,data.count<=SyncProtocolLimits.operationBytes else {throw OSwindError.invalid("Sync operation exceeds its bound")}
        let result=try JSONDecoder().decode(Self.self,from:data)
        guard try result.encoded()==data else {throw OSwindError.invalid("Sync operation is not canonical")}
        return result
    }
}
enum SyncIntegration:Equatable {case updated,conflict,deleted,suppressedByDeletion,duplicate,obsolete}
struct SyncRegister:Codable,Equatable,Sendable {
    let key:SyncObjectKey
    private(set) var clock:SyncClock
    private(set) var deletions:SyncClock
    private(set) var heads:[SyncRevision]
    var isDeleted:Bool {!deletions.counters.isEmpty}
    var isConflicted:Bool {heads.count>1}
    // Stable projection only. Adapters must also surface isConflicted and keep
    // every head; choosing a projection is not user resolution of a conflict.
    var preferred:SyncRevision? {heads.first}
    init(key:SyncObjectKey) {self.key=key;clock = .empty;deletions = .empty;heads=[]}
    private enum CodingKeys:String,CodingKey {case key,clock,deletions,heads}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        key=try c.decode(SyncObjectKey.self,forKey:.key);clock=try c.decode(SyncClock.self,forKey:.clock);deletions=try c.decode(SyncClock.self,forKey:.deletions);heads=try c.decode([SyncRevision].self,forKey:.heads)
        guard heads.count<=SyncProtocolLimits.peers,clock.covers(deletions),!isDeleted || heads.isEmpty else {throw OSwindError.invalid("Invalid sync register")}
        for h in heads {guard h.key==key,h.mutation == .put,try clock.covers(h.clock) else {throw OSwindError.invalid("Invalid sync register head")}}
        for (i,h) in heads.enumerated() {for other in heads.dropFirst(i+1) {
            guard h.dot.replica != other.dot.replica,!h.context.contains(other.dot),!other.context.contains(h.dot) else {throw OSwindError.invalid("Sync register heads are not concurrent")}
        }}
        guard heads==Self.sorted(heads) else {throw OSwindError.invalid("Sync register heads are not ordered")}
        if !isDeleted {
            var complete=SyncClock.empty
            for head in heads {complete=try complete.merged(with:head.clock)}
            guard complete==clock else {throw OSwindError.invalid("Sync register clock has no supporting heads")}
        }
    }
    private static func sorted(_ values:[SyncRevision])->[SyncRevision] {values.sorted {$0.dot.replica==$1.dot.replica ? $0.dot.counter<$1.dot.counter:$0.dot.replica<$1.dot.replica}}
    @discardableResult mutating func integrate(_ revision:SyncRevision)throws->SyncIntegration {
        guard revision.key==key else {throw OSwindError.invalid("Sync operation belongs to another object")}
        if let same=heads.first(where:{$0.dot==revision.dot}) {
            guard same==revision else {throw OSwindError.invalid("Sync writer reused a revision identity")}
            return .duplicate
        }
        for old in heads where old.dot.replica==revision.dot.replica {
            guard old.dot.counter<revision.dot.counter ? revision.context.contains(old.dot):old.context.contains(revision.dot) else {throw OSwindError.invalid("Sync writer forked its causal history")}
        }
        // A deletion seen only inside another revision's context still needs
        // its own barrier when it arrives. An observed counter alone does not
        // say whether that earlier operation was a put or a delete.
        let nextClock=try clock.merged(with:revision.clock)
        if revision.mutation == .delete {
            if deletions.contains(revision.dot) {return .obsolete}
            let nextDeletions=try deletions.observing(revision.dot)
            clock=nextClock;deletions=nextDeletions;heads=[];return .deleted
        }
        for old in heads {
            if revision.context.contains(old.dot) {
                guard try revision.context.covers(old.clock) else {throw OSwindError.invalid("Sync context omits known causal history")}
            }
            if old.context.contains(revision.dot) {
                guard try old.context.covers(revision.clock) else {throw OSwindError.invalid("Sync context omits known causal history")}
            }
        }
        if clock.contains(revision.dot) {return .obsolete}
        if isDeleted {clock=nextClock;return .suppressedByDeletion}
        var next=heads.filter {!revision.context.contains($0.dot)}
        next.append(revision);next=Self.sorted(next)
        guard next.count<=SyncProtocolLimits.peers else {throw OSwindError.invalid("Sync conflicts exceed their bound")}
        clock=nextClock;heads=next
        return isConflicted ? .conflict:.updated
    }
    func encoded()throws->Data {let data=try SyncProtocolLimits.encode(self);guard data.count<=SyncProtocolLimits.stateBytes else {throw OSwindError.invalid("Sync state exceeds its bound")};return data}
    static func decode(_ data:Data)throws->Self {
        guard !data.isEmpty,data.count<=SyncProtocolLimits.stateBytes else {throw OSwindError.invalid("Sync state exceeds its bound")}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard try value.encoded()==data else {throw OSwindError.invalid("Sync state is not canonical")}
        return value
    }
}
