import Foundation
import OSwindCore

func entitiesCLI(_ arguments:[String],store:MemoryStore) async throws -> Any {
    var args=arguments
    let action=args.isEmpty ? "list":args.removeFirst()
    func option(_ flag:String)throws->String? {
        guard args.filter({$0==flag}).count<=1 else {throw OSwindError.invalid("Use each option once")}
        guard let at=args.firstIndex(of:flag) else {return nil}
        guard at+1<args.count else {throw OSwindError.invalid("Missing option value")};let value=args[at+1];args.removeSubrange(at...at+1);return value
    }
    switch action {
    case "list":
        var values=[String:Any]();if let kind=try option("--kind") {values["kind"]=kind};if let query=try option("--query") {values["query"]=query}
        guard args.isEmpty else {throw OSwindError.invalid("Use entity list [--kind person|organization|project|place] [--query TEXT]")}
        return try await Integration.execute("memory_entities",args:values,store:store,embedder:LocalEmbedder())
    case "sources":
        guard args.count==1 else {throw OSwindError.invalid("Use entity sources ID")};return try Integration.json(store.entitySources(args[0]))
    case "create":
        let detail=try option("--notes") ?? ""
        guard args.count==2,let kind=EntityKind(rawValue:args[0]) else {throw OSwindError.invalid("Use entity create KIND NAME [--notes TEXT]")}
        return try Integration.json(store.createEntity(kind:kind,name:args[1],detail:detail))
    case "edit":
        let name=try option("--name"),detail=try option("--notes"),aliases=try option("--aliases")
        guard args.count==1,let old=try store.entity(args[0]) else {throw OSwindError.invalid("Use entity edit ID [--name NAME] [--notes TEXT] [--aliases comma,separated]")}
        try store.editEntity(old.id,name:name ?? old.name,detail:detail ?? old.detail,aliases:aliases.map {$0.split(separator:",").map(String.init)} ?? old.aliases)
        return try Integration.json(store.entity(old.id))
    case "link","unlink":
        guard args.count==2 else {throw OSwindError.invalid("Use entity link|unlink ENTITY_ID SOURCE_ID")}
        if action=="link" {try store.linkEntity(args[0],to:args[1])}else {try store.unlinkEntity(args[0],from:args[1])};return ["updated":true]
    case "merge":
        guard let destination=try option("--into"),args.count==1 else {throw OSwindError.invalid("Use entity merge ID --into ID")}
        try store.mergeEntity(args[0],into:destination);return ["merged":true]
    case "delete":
        guard args.count==1 else {throw OSwindError.invalid("Use entity delete ID")};try store.deleteEntity(args[0]);return ["deleted":true]
    case "progress","index":
        guard args.isEmpty else {throw OSwindError.invalid("Use entity index|progress")}
        let plan=try store.entityIndexPlan(),processor=EntityExtractor.processor(plan)
        if action=="index" {
            let worker=Task.detached(priority:.utility) {
                let prepared=try EntityExtractor.prepare(plan)
                var cursor=""
                while true {
                    try Task.checkCancellation();let ids=try store.pendingEntitySourceIDs(processor:processor,after:cursor)
                    guard !ids.isEmpty else {break}
                    for id in ids {try Task.checkCancellation();try store.indexEntities(id,prepared:prepared);cursor=id}
                }
            }
            try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
        }
        return try Integration.json(store.entityIndexProgress(processor:processor))
    default:throw OSwindError.invalid("Use entity list, create, edit, sources, link, unlink, merge, delete, index or progress")
    }
}
