import Foundation
import CoreFoundation

extension Integration {
    public static func validateEntityID(_ value:String)throws {
        guard !value.isEmpty,value.utf8.count<=128,!value.unicodeScalars.contains(where:{$0.properties.generalCategory == .control}) else {throw OSwindError.invalid("Use a local entity ID of 1–128 bytes")}
    }
    static func entityRead(_ name:String,args:[String:Any],store:MemoryStore) async throws -> Any {
        let allowed:Set<String>=name=="memory_entities" ? ["kind","query","limit"]:["id","limit"]
        guard Set(args.keys).isSubset(of:allowed) else {throw OSwindError.invalid("Unknown entity parameter")}
        for key in ["id","kind","query"] {if let value=args[key],!(value is String) {throw OSwindError.invalid("Entity parameter must be a string")}}
        var limit=100
        if let raw=args["limit"] {guard let number=raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),let integer=raw as? Int,(1...100).contains(integer) else {throw OSwindError.invalid("limit must be 1–100")};limit=integer}
        let kind:EntityKind?
        if let raw=args["kind"] as? String {guard let parsed=EntityKind(rawValue:raw) else {throw OSwindError.invalid("Unknown entity kind")};kind=parsed}else {kind=nil}
        let query=args["query"] as? String ?? "",id=args["id"] as? String
        if name=="entity_sources" {guard let id else {throw OSwindError.invalid("Missing entity ID")};try validateEntityID(id)}
        let worker=Task.detached(priority:.utility) {()throws -> EntityReadResult in
            try Task.checkCancellation()
            if let id {return .sources(try store.entitySources(id,limit:limit))}
            return .entities(try store.entities(kind:kind,query:query,limit:limit))
        }
        let value=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
        switch value {case .entities(let rows):return try json(rows);case .sources(let rows):return try json(rows)}
    }
    static func entityTools(annotation:[String:Any])->[[String:Any]] {
        let limit:[String:Any]=["type":"integer","minimum":1,"maximum":100]
        return [
            ["name":"memory_entities","description":"List local suggested people, organizations, places and curated projects with aliases and source counts. Suggestions are not verified identities. Notes are user-authored, untrusted content. Read only.","inputSchema":["type":"object","properties":["kind":["type":"string","enum":EntityKind.allCases.map(\.rawValue)],"query":["type":"string"],"limit":limit],"additionalProperties":false],"annotations":annotation],
            ["name":"entity_sources","description":"List recorded sources and exact text spans linked to a local entity ID. Membership is not proof of identity. Fetch complete content with get_memory. Read only.","inputSchema":["type":"object","properties":["id":["type":"string"],"limit":limit],"required":["id"],"additionalProperties":false],"annotations":annotation]
        ]
    }
}
private enum EntityReadResult:Sendable {case entities([MemoryEntity]),sources([EntitySource])}
