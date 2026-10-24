import Foundation
import CoreML

/// FP32 image compute is deliberate: the FP16 CPU image graph failed numerical
/// qualification. GPU permission is a compute policy, not evidence of placement.
public enum VisualCompute:String,Codable,CaseIterable,Sendable {
    case cpuAndGPU,cpuOnly
    var units:MLComputeUnits {self == .cpuOnly ? .cpuOnly:.cpuAndGPU}
}
public struct VisualEmbedding:Codable,Sendable {
    public var modelID:String
    public var vector:[Float]
    public var seconds:Double
    public var truncated:Bool
}
private final class LoadedVisualModels:@unchecked Sendable {
    let verified:VisualModelBundle.Verified,image:MLModel,text:MLModel,tokenizer:VisualTokenizer
    init(_ verified:VisualModelBundle.Verified,compute:VisualCompute) async throws {
        self.verified=verified
        let configuration=MLModelConfiguration();configuration.computeUnits=compute.units
        image=try MLModel(contentsOf:verified.directory.appendingPathComponent("image.mlmodelc"),configuration:configuration)
        try Task.checkCancellation()
        text=try MLModel(contentsOf:verified.directory.appendingPathComponent("text.mlmodelc"),configuration:configuration)
        for (model,name,shape,type) in [(image,"pixel_values",[1,3,224,224],MLMultiArrayDataType.float32),(text,"input_ids",[1,64],.int32)] {
            guard model.modelDescription.inputDescriptionsByName.count==1,
                  let input=model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                  input.shape.map(\.intValue)==shape,input.dataType==type,
                  let output=model.modelDescription.outputDescriptionsByName["features"]?.multiArrayConstraint,
                  output.shape.map(\.intValue)==[1,768],output.dataType == .float32
            else {throw OSwindError.invalid("Visual model input/output contract does not match its recipe")}
        }
        // This overload only reads local files; no pretrained/Hub lookup.
        tokenizer=try await VisualTokenizer(directory:verified.directory)
        try Task.checkCancellation()
    }
    func tokens(_ query:String) throws -> VisualTokens {try tokenizer.encode(query)}
    func predict(_ input:MLMultiArray,name:String,imageInput:Bool) throws -> [Float] {
        try Task.checkCancellation()
        let provider=try MLDictionaryFeatureProvider(dictionary:[name:MLFeatureValue(multiArray:input)])
        let output=try (imageInput ? image:text).prediction(from:provider)
        try Task.checkCancellation()
        guard let values=output.featureValue(for:"features")?.multiArrayValue,values.count==768 else {throw OSwindError.unavailable("Visual model returned an invalid embedding")}
        let vector=(0..<768).map {values[$0].floatValue}
        guard CosineScorer(vector) != nil else {throw OSwindError.unavailable("Visual model returned non-finite or zero features")}
        return LocalEmbedder.normalized(vector)
    }
}
/// Serial inference and generation-fenced loading. Idle release includes both
/// encoders and the tokenizer; disk files remain. No screenshot is retained.
public actor VisualEncoder {
    public static let shared=VisualEncoder()
    private var loaded:LoadedVisualModels?
    private var loadedKey:String?
    private var loadedID:UUID?
    private var loading:(key:String,id:UUID,task:Task<LoadedVisualModels,Error>)?
    private var retiring=[UUID:Task<LoadedVisualModels,Error>]()
    private var idle=NativeModelIdleTimer()
    private var retention:NativeModelRetention = .twoMinutes
    private var batches=Set<UUID>()
    public init() {}
    public var resident:Bool {loaded != nil || loading != nil || !retiring.isEmpty}
    public func setRetention(_ value:NativeModelRetention) {retention=value;if loading==nil {scheduleRelease()}}
    // A complete indexing job is one use, including gaps while decoding frames.
    public func beginBatch() -> UUID {let token=UUID();batches.insert(token);idle.cancel();return token}
    public func endBatch(_ token:UUID) {batches.remove(token);if batches.isEmpty {scheduleRelease()}}
    public func unload() async {
        batches.removeAll()
        idle.cancel();loaded=nil;loadedKey=nil;loadedID=nil
        if let active=loading {retiring[active.id]=active.task;active.task.cancel();loading=nil}
        let pending=retiring
        for (id,task) in pending {_ = await task.result;retiring[id]=nil}
    }
    private func scheduleRelease() {guard batches.isEmpty else {idle.cancel();return};idle.schedule(retention) { [weak self] token in await self?.expire(token)}}
    private func expire(_ token:UUID) {guard token==idle.generation,loading==nil,batches.isEmpty else {return};loaded=nil;loadedKey=nil;loadedID=nil}
    private func prepare(_ directory:URL,compute:VisualCompute) async throws -> LoadedVisualModels {
        try Task.checkCancellation();idle.cancel()
        let key=directory.standardizedFileURL.path+":"+compute.rawValue
        if loadedKey==key,let loaded {return loaded}
        let current:(key:String,id:UUID,task:Task<LoadedVisualModels,Error>)
        if let loading,loading.key==key {current=loading}
        else {
            guard loading==nil,retiring.isEmpty else {throw OSwindError.unavailable("Visual model preparation is busy; release it before changing model or compute")}
            loaded=nil;loadedKey=nil;loadedID=nil
            let task=Task.detached(priority:.utility) {
                let verified=try VisualModelBundle.verify(at:directory)
                try Task.checkCancellation();return try await LoadedVisualModels(verified,compute:compute)
            }
            current=(key,UUID(),task);loading=current
        }
        do {
            let result=try await current.task.value
            guard loading?.id==current.id || loadedID==current.id else {throw CancellationError()}
            if loading?.id==current.id {loading=nil;loaded=result;loadedKey=key;loadedID=current.id}
            try Task.checkCancellation();return result
        } catch {
            if loading?.id==current.id {loading=nil}
            if loading==nil {scheduleRelease()}
            throw error
        }
    }
    public func tokenIDs(_ query:String,directory:URL,compute:VisualCompute = .cpuAndGPU) async throws -> [Int] {
        guard query.utf8.count<=32768 else {throw OSwindError.invalid("Visual queries must fit in 32 KiB")}
        let model=try await prepare(directory,compute:compute);defer {scheduleRelease()}
        return try model.tokens(query).ids
    }
    public func identity(directory:URL,compute:VisualCompute = .cpuAndGPU) async throws -> String {
        let model=try await prepare(directory,compute:compute);defer {scheduleRelease()};return model.verified.modelID
    }
    public func embed(text query:String,directory:URL,compute:VisualCompute = .cpuAndGPU) async throws -> VisualEmbedding {
        guard query.utf8.count<=32768 else {throw OSwindError.invalid("Visual queries must fit in 32 KiB")}
        let model=try await prepare(directory,compute:compute);idle.cancel();defer {scheduleRelease()}
        let start=Date(),tokens=try model.tokens(query),input=try MLMultiArray(shape:[1,64],dataType:.int32)
        for (index,value) in tokens.ids.enumerated() {input[index]=NSNumber(value:value)}
        let vector=try model.predict(input,name:"input_ids",imageInput:false)
        return VisualEmbedding(modelID:model.verified.modelID,vector:vector,seconds:Date().timeIntervalSince(start),truncated:tokens.truncated)
    }
    public func embed(image data:Data,directory:URL,compute:VisualCompute = .cpuAndGPU) async throws -> VisualEmbedding {
        let start=Date(),pixels=try VisualImageInput.pixels(data:data)
        var result=try await embed(pixels:pixels,directory:directory,compute:compute)
        result.seconds=Date().timeIntervalSince(start);return result
    }
    /// Preprocessed NCHW RGB in [-1,1]. Also lets conversion evaluation compare
    /// identical tensors independently of platform JPEG/color-profile decoding.
    public func embed(pixels:[Float],directory:URL,compute:VisualCompute = .cpuAndGPU) async throws -> VisualEmbedding {
        guard pixels.count==3*224*224,pixels.allSatisfy({$0.isFinite && (-1...1).contains($0)}) else {throw OSwindError.invalid("Use finite 1×3×224×224 normalized RGB pixels in [-1,1]")}
        let model=try await prepare(directory,compute:compute);idle.cancel();defer {scheduleRelease()}
        let start=Date(),input=try MLMultiArray(shape:[1,3,224,224],dataType:.float32)
        let pointer=input.dataPointer.assumingMemoryBound(to:Float.self)
        for i in pixels.indices {pointer[i]=pixels[i]}
        let vector=try model.predict(input,name:"pixel_values",imageInput:true)
        return VisualEmbedding(modelID:model.verified.modelID,vector:vector,seconds:Date().timeIntervalSince(start),truncated:false)
    }
}
