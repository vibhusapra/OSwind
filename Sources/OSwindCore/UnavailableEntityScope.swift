import Foundation

/// Shared native selector discriminator. Older String-based readers refuse
/// this object instead of ignoring an unfamiliar unavailable-scope property.
struct UnavailableEntitySelector:Codable {
    enum State:String,Codable {case unavailable}
    let state:State
    init() {state = .unavailable}
}

/// An unavailable saved restriction is never an unrestricted query. Optional
/// provenance describes its former entity; it grants no entity lookup authority.
public struct UnavailableEntityScope:Codable,Equatable,Sendable {
    public struct Reference:Codable,Equatable,Sendable {
        public let origin:String
        public let lifetime:String
        public init(origin:String,lifetime:String)throws {
            try SyncProtocolLimits.uuid(origin);try SyncProtocolLimits.uuid(lifetime)
            self.origin=origin;self.lifetime=lifetime
        }
        private enum CodingKeys:String,CodingKey {case origin,lifetime}
        public init(from decoder:Decoder)throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            try self.init(origin:c.decode(String.self,forKey:.origin),lifetime:c.decode(String.self,forKey:.lifetime))
        }
    }
    public let original:Reference?
    // Only a matching current journal and actual barrier may reconstruct an
    // earlier active wire reference. A quiet restore must keep it unavailable.
    struct Projection:Codable,Equatable,Sendable {
        let origin:String,generation:String,group:String,epoch:String
        func validate()throws {for id in [origin,generation,group,epoch] {try SyncProtocolLimits.uuid(id)}}
    }
    var projection:Projection?
    public init(original:Reference?=nil) {self.original=original;projection=nil}
    init(original:Reference,projection:Projection)throws {
        try projection.validate();self.original=original;self.projection=projection
    }
    private enum CodingKeys:String,CodingKey {case original,projection}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        original=try c.decodeIfPresent(Reference.self,forKey:.original)
        projection=try c.decodeIfPresent(Projection.self,forKey:.projection)
        if let projection {
            try projection.validate()
            guard original != nil else {throw OSwindError.invalid("Unavailable scope projection lacks its original entity")}
        }
    }
}
extension SearchFilter {
    public func requireAvailableEntityScope()throws {
        guard unavailableEntityScope==nil else {throw OSwindError.unavailable("This entity scope is unavailable. Choose another scope before searching.")}
    }
}
