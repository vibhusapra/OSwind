import Foundation
import OSwindCore
import Darwin

struct VisualProbeInput:Decodable {
    var queries:[String]
    var images:[String]
}
struct VisualProbeOutput:Encodable {
    var modelID:String
    var requestedCompute:VisualCompute
    var scope:String="Local runtime probe; requested compute policy does not establish actual device placement"
    var preparationAndFirstTextSeconds:Double
    var queryTokens:[[Int]]
    var text:[VisualEmbedding]
    var images:[VisualEmbedding]
    var similarities:[[Double]]
    var pixelExported:Bool
}
@MainActor func runVisualModelCLI() async throws {
    let directory=try validatedOption("--model-dir")
    guard let action=args.first else {throw OSwindError.invalid("Use vision prepare|index|search|status|probe [--model-dir DIRECTORY]")}
    args.removeFirst()
    let pixelPath=try validatedOption("--pixel-output")
    let computeOverride=try validatedOption("--compute")
    if action=="prepare" {
        guard directory==nil,pixelPath==nil,computeOverride==nil else {throw OSwindError.invalid("Use vision prepare [--cache-root DIRECTORY] [--assets-root DIRECTORY] [--use-model]")}
        let cache=try validatedOption("--cache-root").map {URL(fileURLWithPath:$0,isDirectory:true)},assets=try validatedOption("--assets-root").map {URL(fileURLWithPath:$0,isDirectory:true)}
        let useModel=args.contains("--use-model");guard args.filter({$0=="--use-model"}).count<=1 else {throw OSwindError.invalid("Use --use-model once")};args.removeAll {$0=="--use-model"};guard args.isEmpty else {throw OSwindError.invalid("Unknown visual preparation option")}
        let reporter=BackupCLIProgress()
        do {
            let installation=try await runAsyncCLI(cancellationMessage:"Stopping visual model preparation and its child processes; verified public downloads remain cached.") {
                try await VisualModelPreparation.prepare(cache:cache,assetsRoot:assets) {state in reporter.update(.init(phase:state.phase,completedItems:state.completedBytes,totalItems:state.totalBytes,unit:"bytes"))}
            }
            if useModel {var settings=AppSettings.load(root:root);settings.search.visual.enabled=true;settings.search.visual.modelDirectory=installation.directory.path;try settings.save(root:root)}
            try encoded(installation)
        } catch is CancellationError {FileHandle.standardError.write(Data("Visual model preparation cancelled.\n".utf8));exit(130)}
        return
    }
    if action=="index" || action=="search" {
        guard pixelPath==nil else {throw OSwindError.invalid("Pixel export is available only in an explicit probe")}
        let useModel=args.contains("--use-model")
        guard args.filter({$0=="--use-model"}).count<=1,action=="index" || !useModel else {throw OSwindError.invalid("Use --use-model once, with vision index")}
        args.removeAll {$0=="--use-model"}
        var settings=AppSettings.load(root:root),configuration=settings.search.visual
        configuration.enabled=true
        if let directory {configuration.modelDirectory=URL(fileURLWithPath:directory,isDirectory:true).path}
        if let computeOverride {guard let compute=VisualCompute(rawValue:computeOverride) else {throw OSwindError.invalid("Visual compute must be cpuAndGPU or cpuOnly")};configuration.compute=compute}
        _ = try configuration.selectedDirectory()
        if action=="index",!args.isEmpty {throw OSwindError.invalid("Use vision index [--model-dir DIRECTORY] [--use-model]")}
        let filter=action=="search" ? try searchFilter():SearchFilter()
        let store=try MemoryStore(root:root);defer {try? store.close()}
        let engine=VisualRetrievalEngine(store:store),config=configuration,policy=settings.privacy
        if action=="search" {
            try encoded(await engine.search(filter,configuration:configuration,policy:policy,interpretQuery:!literalQuery));return
        }
        let reporter=BackupCLIProgress(),allowLowPower=settings.search.indexOnLowPower
        do {
            let result=try await runAsyncCLI(cancellationMessage:"Stopping visual indexing; completed sources are saved.") {
                try await engine.rebuild(configuration:config,policy:policy,shouldContinue:{
                    (allowLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)
                }) {state in reporter.update(LibraryBackupProgress(phase:"Indexing visuals",completedItems:Int64(state.processedSources),totalItems:Int64(state.totalSources),unit:"sources"))}
            }
            if useModel {settings.search.visual=configuration;try settings.save(root:root)}
            try encoded(result);if result.failedSources>0 {exit(2)}
        } catch is CancellationError {FileHandle.standardError.write(Data("Visual indexing cancelled; completed sources remain.\n".utf8));exit(130)}
        return
    }
    guard let directory else {throw OSwindError.invalid("Use --model-dir DIRECTORY for vision status or probe")}
    let computeText=computeOverride ?? "cpuAndGPU"
    guard let compute=VisualCompute(rawValue:computeText) else {throw OSwindError.invalid("Visual compute must be cpuAndGPU or cpuOnly")}
    let location=URL(fileURLWithPath:directory,isDirectory:true)
    if action=="status" {
        guard args.isEmpty,pixelPath==nil else {throw OSwindError.invalid("Use vision status --model-dir DIRECTORY")}
        let verified=try await runBackupCLI {try VisualModelBundle.verify(at:location)}
        try emit(["modelID":verified.modelID,"bytes":verified.bundle.model.bytes,"files":verified.bundle.model.files.count,"recipe":verified.bundle.conversionRecipe,"directory":location.path,"downloaded":false]);return
    }
    guard action=="probe",args.count==1 else {throw OSwindError.invalid("Use vision probe FIXTURE_JSON --model-dir DIRECTORY")}
    let url=URL(fileURLWithPath:args[0]),size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max
    guard size<=2*1024*1024 else {throw OSwindError.invalid("Visual probe input exceeds 2 MiB")}
    let fixture=try JSONDecoder().decode(VisualProbeInput.self,from:Data(contentsOf:url))
    guard !fixture.queries.isEmpty,fixture.queries.count<=1024,!fixture.images.isEmpty,fixture.images.count<=256,
          fixture.queries.allSatisfy({$0.utf8.count<=32768}),fixture.images.allSatisfy({$0.hasPrefix("/") && !$0.utf8.contains(0)})
    else {throw OSwindError.invalid("Use 1–1024 bounded queries and 1–256 absolute image paths")}
    var pixelDirectory:URL?
    if let pixelPath {
        let destination=URL(fileURLWithPath:pixelPath,isDirectory:true),resolved=destination.standardizedFileURL.resolvingSymlinksInPath(),model=location.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path != model.path,!resolved.path.hasPrefix(model.path+"/"),mkdir(destination.path,0o700)==0 else {throw OSwindError.invalid("Choose a NEW pixel export directory outside the model bundle with an existing parent")}
        pixelDirectory=destination
    }
    // Explicit fixture only; no MemoryStore, settings, Keychain, capture or API.
    let runtime=VisualEncoder(),start=Date()
    var texts=[VisualEmbedding](),tokens=[[Int]](),images=[VisualEmbedding](),firstSeconds=0.0
    for query in fixture.queries {
        try Task.checkCancellation();texts.append(try await runtime.embed(text:query,directory:location,compute:compute))
        if texts.count==1 {firstSeconds=Date().timeIntervalSince(start)}
        tokens.append(try await runtime.tokenIDs(query,directory:location,compute:compute))
    }
    for path in fixture.images {
        try Task.checkCancellation();let file=URL(fileURLWithPath:path)
        guard (try file.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max<=64*1024*1024 else {throw OSwindError.invalid("Visual image exceeds 64 MiB")}
        let before=Date(),pixels=try VisualImageInput.pixels(data:Data(contentsOf:file)),preprocessing=Date().timeIntervalSince(before)
        var value=try await runtime.embed(pixels:pixels,directory:location,compute:compute);value.seconds += preprocessing;images.append(value)
        if let pixelDirectory {try pixels.withUnsafeBytes {try Data($0).write(to:pixelDirectory.appendingPathComponent("input-\(images.count-1).f32"),options:.withoutOverwriting)}}
    }
    await runtime.unload()
    guard let identity=texts.first?.modelID,(texts+images).allSatisfy({$0.modelID==identity}) else {throw OSwindError.invalid("Visual model changed during probe")}
    try encoded(VisualProbeOutput(modelID:identity,requestedCompute:compute,preparationAndFirstTextSeconds:firstSeconds,queryTokens:tokens,text:texts,images:images,similarities:texts.map {query in images.map {LocalEmbedder.cosine(query.vector,$0.vector)}},pixelExported:pixelDirectory != nil))
}
