import Foundation
import OSwindCore

func routinesCLI(_ arguments:[String],store:MemoryStore,embedder:LocalEmbedder) async throws -> Any {
    var args=arguments
    let action=args.isEmpty ? "list":args.removeFirst()
    func option(_ name:String) throws -> String? {
        guard args.filter({$0==name}).count<=1 else {throw OSwindError.invalid("Use \(name) once")}
        guard let index=args.firstIndex(of:name) else {return nil}
        guard index+1<args.count else {throw OSwindError.invalid("Enter a value after \(name)")};let value=args[index+1];args.removeSubrange(index...index+1);return value
    }
    let at=try option("--at").map {try QueryScopeResolver.instant($0)} ?? Date()
    switch action {
    case "template":
        guard args.isEmpty else {throw OSwindError.invalid("Use routine template")};return try Integration.json(RoutineDefinition())
    case "list":
        guard args.isEmpty else {throw OSwindError.invalid("Use routine list")};return try Integration.json(store.routines())
    case "put":
        let rawRevision=try option("--revision"),revision=rawRevision.flatMap(Int.init)
        if rawRevision != nil && revision==nil {throw OSwindError.invalid("Routine revision must be an integer")}
        guard args.count==1 else {throw OSwindError.invalid("Use routine put DEFINITION_JSON [--revision N]")}
        let file=try FileHandle(forReadingFrom:URL(fileURLWithPath:args[0]));defer {try? file.close()}
        let data=try file.read(upToCount:32769) ?? Data();guard data.count<=32768 else {throw OSwindError.invalid("Routine definition exceeds 32 KiB")}
        let definition=try JSONDecoder().decode(RoutineDefinition.self,from:data)
        return try Integration.json(store.saveRoutine(definition,expectedRevision:revision,now:at,policy:AppSettings.load(root:store.root).privacy))
    case "history":
        guard args.count<=1 else {throw OSwindError.invalid("Use routine history [ID]")};return try Integration.json(store.routineRuns(args.first))
    case "delete":
        guard args.count==1 else {throw OSwindError.invalid("Use routine delete ID")};try store.deleteRoutine(args[0]);return ["deleted":true]
    case "scheduler":
        guard args.count==1,["on","off"].contains(args[0]) else {throw OSwindError.invalid("Use routine scheduler on|off")}
        var settings=AppSettings.load(root:store.root);settings.routinesEnabled=args[0]=="on";try settings.save(root:store.root)
        return ["enabled":settings.routinesEnabled,"scope":"Persisted for the app or an explicit tick; this command does not start a background process."]
    case "preview":
        guard args.count==1,let item=try store.routines().first(where:{$0.id==args[0]}) else {throw OSwindError.invalid("Use routine preview EXISTING_ID")}
        return ["routine":try Integration.json(item),"source_scope":try Integration.json(item.definition.filter(at:at)),"at":try ISOTime.string(at),"executes":false]
    case "tick","run":
        guard action=="tick" ? args.isEmpty:args.count==1 else {throw OSwindError.invalid("Use routine tick or routine run ID")}
        let settings=AppSettings.load(root:store.root),runner=RoutineRunner(store:store,embedder:embedder)
        let run:RoutineRun?
        if action=="tick" {run=try await runner.runDue(settings:settings,now:at)} else {run=try await runner.runNow(args[0],settings:settings,now:at)}
        if let run {return try Integration.json(run)};return ["claimed":false,"reason":"No eligible occurrence, automatic schedules disabled, or another run is active."]
    default:throw OSwindError.invalid("Use routine template, put, list, preview, history, run, tick, scheduler or delete")
    }
}
