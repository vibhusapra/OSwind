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
    guard let directory=try validatedOption("--model-dir"),let action=args.first else {throw OSwindError.invalid("Use vision status|probe FIXTURE_JSON --model-dir DIRECTORY [--compute cpuAndGPU|cpuOnly]")}
    args.removeFirst()
    let pixelPath=try validatedOption("--pixel-output")
    let computeText=try validatedOption("--compute") ?? "cpuAndGPU"
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
