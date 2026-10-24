import Foundation
import AVFoundation

public struct VisualSearchConfiguration:Codable,Equatable,Sendable {
    public var enabled=false
    public var automaticIndex=true
    public var modelDirectory=""
    public var compute:VisualCompute = .cpuAndGPU
    public var retention:NativeModelRetention = .twoMinutes
    public init() {}
    enum CodingKeys:CodingKey {case enabled,automaticIndex,modelDirectory,compute,retention}
    public init(from decoder:Decoder) throws {
        self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
        enabled=try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? enabled
        automaticIndex=try c.decodeIfPresent(Bool.self,forKey:.automaticIndex) ?? automaticIndex
        modelDirectory=try c.decodeIfPresent(String.self,forKey:.modelDirectory) ?? modelDirectory
        compute=try c.decodeIfPresent(VisualCompute.self,forKey:.compute) ?? compute
        retention=try c.decodeIfPresent(NativeModelRetention.self,forKey:.retention) ?? retention
    }
    public func selectedDirectory() throws -> URL {
        guard enabled else {throw OSwindError.unavailable("Enable visual memory in Models settings to search by appearance")}
        guard modelDirectory.hasPrefix("/"),!modelDirectory.utf8.contains(0) else {throw OSwindError.unavailable("Choose a prepared local visual model in Models settings")}
        return URL(fileURLWithPath:modelDirectory,isDirectory:true)
    }
}
protocol VisualEmbeddingService:Sendable {
    func identity(directory:URL,compute:VisualCompute) async throws -> String
    func beginBatch() async -> UUID
    func endBatch(_ token:UUID) async
    func setRetention(_ value:NativeModelRetention) async
    func embed(text:String,directory:URL,compute:VisualCompute) async throws -> VisualEmbedding
    func embed(image:Data,directory:URL,compute:VisualCompute) async throws -> VisualEmbedding
    func embed(pixels:[Float],directory:URL,compute:VisualCompute) async throws -> VisualEmbedding
}
extension VisualEncoder:VisualEmbeddingService {}
private enum VisualIndexInterruption:LocalizedError {
    case modelChanged
    var errorDescription:String? {"The visual model changed during indexing. Restart with the selected bundle."}
}

public struct VisualIndexProgress:Codable,Sendable {
    public var modelID:String
    public var totalSources:Int
    public var processedSources=0
    public var indexedSources=0
    public var indexedFrames=0
    public var skippedSources=0
    public var failedSources=0
    public var errors=[String]()
}
final class VisualReplayDecoder {
    private var generator:AVAssetImageGenerator?
    private init(_ generator:AVAssetImageGenerator) {self.generator=generator}
    static func open(_ url:URL,maxDimension:Int=4096) async throws -> VisualReplayDecoder {
        let asset=AVURLAsset(url:url),duration=try await asset.load(.duration).seconds
        guard duration.isFinite,duration>0,duration<=120.1,let track=try await asset.loadTracks(withMediaType:.video).first else {throw OSwindError.invalid("Invalid or oversized replay asset")}
        let size=try await track.load(.naturalSize)
        guard size.width.isFinite,size.height.isFinite,size.width>0,size.height>0,size.width<=4096,size.height<=4096 else {throw OSwindError.invalid("Replay dimensions exceed the visual encoder limit")}
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
        generator.maximumSize=CGSize(width:maxDimension,height:maxDimension);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        return VisualReplayDecoder(generator)
    }
    func pixels(at seconds:Double) async throws -> (values:[Float],time:Double) {
        let frame=try await image(at:seconds)
        return (try VisualImageInput.pixels(image:frame.image),frame.time)
    }
    func image(at seconds:Double) async throws -> (image:CGImage,time:Double) {
        try Task.checkCancellation();guard let generator else {throw CancellationError()}
        let frame=try await withTaskCancellationHandler {try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:60000))} onCancel: {generator.cancelAllCGImageGeneration()}
        try Task.checkCancellation();let actual=frame.actualTime.seconds
        guard actual.isFinite,actual>=0,abs(actual-seconds)<=0.1 else {throw OSwindError.unavailable("Decoded replay frame does not match its recorded timestamp")}
        return (frame.image,actual)
    }
    func close() {generator?.cancelAllCGImageGeneration();generator=nil}
    deinit {close()}
}

public final class VisualRetrievalEngine:@unchecked Sendable {
    private let store:MemoryStore
    private let encoder:any VisualEmbeddingService
    public init(store:MemoryStore) {self.store=store;encoder=VisualEncoder.shared}
    init(store:MemoryStore,encoder:any VisualEmbeddingService) {self.store=store;self.encoder=encoder}
    private func batch<T>(_ operation:() async throws -> T) async rethrows -> T {
        let token=await encoder.beginBatch()
        do {let result=try await operation();await encoder.endBatch(token);return result}
        catch {await encoder.endBatch(token);throw error}
    }
    private func configured(_ configuration:VisualSearchConfiguration) async throws -> (URL,String) {
        let directory=try configuration.selectedDirectory();await encoder.setRetention(configuration.retention)
        return (directory,try await encoder.identity(directory:directory,compute:configuration.compute))
    }
    public func search(_ input:SearchFilter,configuration:VisualSearchConfiguration,policy:PrivacyPolicy=PrivacyPolicy(),interpretQuery:Bool=true,now:Date=Date(),timeZone:TimeZone = .current,expressionPlan:SearchExpressionPlan?=nil) async throws -> RetrievalResult {
        let start=Date(),resolution=try store.resolveQueryScope(input,interpret:interpretQuery,now:now,timeZone:timeZone),filter=resolution.filter
        let expression=try expressionPlan ?? SearchExpressionPlan.make(filter.query,interpret:interpretQuery)
        if expression.semanticText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let hits=try store.recentVisualSources(filter).filter {Self.allowed($0.memory,policy:policy)}
            return RetrievalResult(hits:hits,warnings:[],modelID:nil,duration:Date().timeIntervalSince(start),strategy:"visual-recent",resolution:resolution)
        }
        let directory=try configuration.selectedDirectory();await encoder.setRetention(configuration.retention)
        let query=try await encoder.embed(text:expression.semanticText,directory:directory,compute:configuration.compute);try Task.checkCancellation()
        let store=self.store,worker=Task.detached(priority:.userInitiated) {try store.searchVisual(filter,vector:query.vector,modelID:query.modelID,expression:expression,policy:policy)}
        let found=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
        let coverage=try store.visualCoverage(modelID:query.modelID,filter:filter)
        var warnings=["Matches use image appearance. Open the recorded image or frame to verify its content."]
        if coverage.indexedSources<coverage.sources {warnings.append("Visual vectors cover \(coverage.indexedSources) of \(coverage.sources) retained sources in this range. Build or resume the visual index in Models settings.")}
        if found.invalidMedia>0 {warnings.append("\(found.invalidMedia) indexed sources changed or have missing media; those matches were omitted. Rebuild the visual index.")}
        if query.truncated {warnings.append("The visual query was truncated to the model's 63 content tokens. Use a shorter description.")}
        if expression.hasConstraints {warnings.append("Quotes and Boolean operators filter recorded text; image appearance ranks the remaining sources.")}
        return RetrievalResult(hits:found.hits,warnings:warnings,modelID:query.modelID,duration:Date().timeIntervalSince(start),strategy:"visual-exact-source-validated",resolution:resolution)
    }
    static func allowed(_ memory:Memory,policy:PrivacyPolicy) -> Bool {
        let browser=WindowContext(app:memory.app,bundle:memory.bundleID,pid:0,title:memory.title,url:memory.url,accessibilityText:"",secure:false).browser
        return policy.exclusion(app:memory.bundleID,title:memory.title,url:memory.url,isBrowser:browser)==nil
    }
    @discardableResult public func index(_ memories:[Memory],configuration:VisualSearchConfiguration,policy:PrivacyPolicy=PrivacyPolicy(),shouldContinue:@escaping @Sendable ()->Bool={true}) async throws -> VisualIndexProgress {
        try Task.checkCancellation();guard shouldContinue() else {throw OSwindError.unavailable("Visual indexing deferred by power or thermal policy. Completed sources are saved.")}
        return try await batch {
        let (directory,identity)=try await configured(configuration)
        var result=VisualIndexProgress(modelID:identity,totalSources:memories.count)
        for memory in memories {try await indexOne(memory.id,directory:directory,identity:identity,configuration:configuration,policy:policy,shouldContinue:shouldContinue,result:&result)}
        return result
        }
    }
    @discardableResult public func rebuild(configuration:VisualSearchConfiguration,policy:PrivacyPolicy=PrivacyPolicy(),pendingOnly:Bool=false,shouldContinue:@escaping @Sendable ()->Bool={true},progress:@escaping @Sendable (VisualIndexProgress)->Void={_ in}) async throws -> VisualIndexProgress {
        try Task.checkCancellation();guard shouldContinue() else {throw OSwindError.unavailable("Visual indexing deferred by power or thermal policy. Completed sources are saved.")}
        return try await batch {
        let (directory,identity)=try await configured(configuration)
        var result=VisualIndexProgress(modelID:identity,totalSources:try store.visualCoverage(modelID:identity).sources),cursor=""
        progress(result)
        while true {
            try Task.checkCancellation();guard shouldContinue() else {throw OSwindError.unavailable("Visual indexing deferred by power or thermal policy. Completed sources are saved.")}
            let batch=try store.visualSources(afterID:cursor,limit:8,missingFor:pendingOnly ? identity:nil);guard let last=batch.last else {break}
            for memory in batch {try await indexOne(memory.id,directory:directory,identity:identity,configuration:configuration,policy:policy,shouldContinue:shouldContinue,result:&result);progress(result)}
            cursor=last.id
        }
        return result
        }
    }
    private func indexOne(_ id:String,directory:URL,identity:String,configuration:VisualSearchConfiguration,policy:PrivacyPolicy,shouldContinue:@escaping @Sendable ()->Bool,result:inout VisualIndexProgress) async throws {
        try Task.checkCancellation();guard shouldContinue() else {throw OSwindError.unavailable("Visual indexing deferred by power or thermal policy. Completed sources are saved.")}
        defer {result.processedSources+=1}
        do {
            guard let memory=try store.get(id),let plan=try VisualSourcePlan.make(memory) else {result.skippedSources+=1;return}
            guard Self.allowed(memory,policy:policy) else {try store.removeVisualVectors(id,modelID:identity);result.skippedSources+=1;return}
            let snapshot:any VisualMediaSnapshot
            if plan.kind == .image {
                guard let image=try VisualImageSnapshot.make(store:store,id:id) else {result.skippedSources+=1;return};snapshot=image
            } else {
                guard let video=try VisualVideoSnapshot.make(store:store,id:id) else {result.skippedSources+=1;return};snapshot=video
            }
            defer {snapshot.release()}
            let current=try snapshot.withAdmission(for:store) {$0}
            guard Self.allowed(current,policy:policy) else {try store.removeVisualVectors(id,modelID:identity);result.skippedSources+=1;return}
            if try store.visualVectorsCurrent(plan:snapshot.plan,mediaSHA256:snapshot.sha256,modelID:identity) {result.indexedSources+=1;result.indexedFrames+=snapshot.plan.points.count;return}
            var records=[VisualFrameVector]()
            if let image=snapshot as? VisualImageSnapshot {
                let encoded=try await encoder.embed(image:image.data,directory:directory,compute:configuration.compute)
                guard encoded.modelID==identity else {throw VisualIndexInterruption.modelChanged}
                records=[VisualFrameVector(point:image.plan.points[0],decodedTime:nil,vector:encoded.vector)]
            } else if let video=snapshot as? VisualVideoSnapshot {
                let decoder=try await VisualReplayDecoder.open(video.url);defer {decoder.close()}
                for point in video.plan.points {
                    try Task.checkCancellation();guard shouldContinue() else {throw OSwindError.unavailable("Visual replay indexing deferred by power or thermal policy")}
                    let input=try await decoder.pixels(at:point.time!),encoded=try await encoder.embed(pixels:input.values,directory:directory,compute:configuration.compute)
                    guard encoded.modelID==identity else {throw VisualIndexInterruption.modelChanged}
                    records.append(VisualFrameVector(point:point,decodedTime:input.time,vector:encoded.vector))
                }
            }
            try Task.checkCancellation();guard shouldContinue() else {throw OSwindError.unavailable("Visual indexing deferred before admission")}
            _ = try store.saveVisualVectors(records,snapshot:snapshot,modelID:identity)
            result.indexedSources+=1;result.indexedFrames+=records.count
        } catch is CancellationError {throw CancellationError()}
        catch let error as VisualIndexInterruption {throw error}
        catch {
            try Task.checkCancellation()
            guard shouldContinue() else {throw OSwindError.unavailable("Visual indexing deferred by power or thermal policy. Completed sources are saved.")}
            // A failed source cannot retain a stale ready flag. Continue other
            // sources, with bounded errors and explicit failed/partial counts.
            try store.removeVisualVectors(id,modelID:identity);result.failedSources+=1
            if result.errors.count<20 {result.errors.append("\(id): \(error.localizedDescription)")}
        }
    }
}
