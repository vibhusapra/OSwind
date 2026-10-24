import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ReplayFrameInput:@unchecked Sendable {
    var buffer:CVPixelBuffer
    var time:Double
    var capturedAt:Date
    var app:String
    var bundle:String
    var title:String
    var url:String?
    var display:String
    var text:String
    var regions:[TextRegion]
    var secure=false
    var browser=false
    var contextKey:String {[bundle,title,url ?? "",display].joined(separator:"\u{0}")}
}
actor VisualChunkRecorder {
    private final class Chunk {
        let id=UUID().uuidString
        let workspace:BackupWorkspace
        let encoder:ReplayVideoEncoder
        let first:ReplayFrameInput
        let interval:Double
        var frames=[VisualFrame]()
        var lastSourceTime:Double
        init(store:MemoryStore,first:ReplayFrameInput,interval:Double,codec:String,hardware:Bool) throws {
            self.first=first;self.interval=interval;lastSourceTime=first.time
            workspace=try store.libraryWorkspace("oswind-visual-recording",bucket:.video)
            encoder=try ReplayVideoEncoder(url:workspace.url.appendingPathComponent("clip.mov"),width:CVPixelBufferGetWidth(first.buffer),height:CVPixelBufferGetHeight(first.buffer),frameInterval:interval,codec:codec,hardwareRequired:hardware)
        }
    }
    private let store:MemoryStore
    private let embedder:LocalEmbedder?
    private let codec:String
    private let hardware:Bool
    private let gate:ReplayCommitGate
    private let onMemory:@Sendable (Memory) async -> Void
    private var chunk:Chunk?
    private var pending:Chunk?
    private var closed=false,discarded=false
    private var operationActive=false
    private var waiters=[CheckedContinuation<Void,Never>]()
    private func acquire() async {
        if !operationActive {operationActive=true;return}
        await withCheckedContinuation {waiters.append($0)}
    }
    private func release() {
        if waiters.isEmpty {operationActive=false} else {waiters.removeFirst().resume()}
    }
    init(store:MemoryStore,embedder:LocalEmbedder?=nil,codec:String="hevc",hardwareRequired:Bool=true,gate:ReplayCommitGate=ReplayCommitGate(),onMemory:@escaping @Sendable (Memory) async -> Void={_ in}) {
        self.store=store;self.embedder=embedder;self.codec=codec;hardware=hardwareRequired;self.gate=gate;self.onMemory=onMemory
    }
    func append(_ frame:ReplayFrameInput,privacy:PrivacyPolicy,interval:Double) async throws {
        await acquire();defer {release()}
        try Task.checkCancellation();guard !closed else {return}
        guard frame.time.isFinite,frame.capturedAt.timeIntervalSinceReferenceDate.isFinite,interval.isFinite,interval>=0.25,interval<=45 else {throw OSwindError.invalid("Invalid replay clock")}
        if frame.secure || privacy.exclusion(app:frame.bundle,title:frame.title,url:frame.url,isBrowser:frame.browser) != nil {try await finishCurrent(endAt:frame.time);return}
        let clean=privacy.sanitize(frame.text),title=privacy.sanitize(frame.title),url=privacy.sanitize(frame.url ?? "")
        let rawAllowed=privacy.retainImages && !clean.redacted && !title.redacted && !url.redacted && !frame.regions.contains {privacy.sanitize($0.text).redacted}
        guard rawAllowed else {
            try await finishCurrent(endAt:frame.time);guard !closed else {return}
            var memory=Memory(timestamp:frame.capturedAt,kind:.screen,app:privacy.sanitize(frame.app).text,bundleID:frame.bundle,title:title.text,url:url.text.isEmpty ? nil:url.text,text:clean.text,display:frame.display,regions:[])
            memory.embedding=embedder?.embed(memory.searchableText);memory.embeddingModel=memory.embedding==nil ? nil:embedder?.modelID
            try gate.commit {try store.insert(memory)};await onMemory(memory);return
        }
        if let current=chunk {
            let changed=current.first.contextKey != frame.contextKey || current.encoder.width != CVPixelBufferGetWidth(frame.buffer) || current.encoder.height != CVPixelBufferGetHeight(frame.buffer) || current.interval != interval
            let gap=frame.time-current.lastSourceTime>interval*1.75
            if changed || gap || frame.time-current.first.time>=max(5,interval*2) || current.frames.count>=120 || current.frames.reduce(0,{$0+$1.text.count})+clean.text.count>900000 {try await finishCurrent(endAt:frame.time)}
        }
        guard !closed else {return}
        if chunk==nil {var admitted=frame;admitted.app=privacy.sanitize(frame.app).text;admitted.title=title.text;admitted.url=url.text.isEmpty ? nil:url.text;chunk=try Chunk(store:store,first:admitted,interval:interval,codec:codec,hardware:hardware)}
        guard let current=chunk else {return}
        let time=frame.time-current.first.time
        let entry=VisualFrame(time:time,text:clean.text,regions:frame.regions)
        // Validate before retaining pixels; an invalid source never reaches an encoder.
        _ = try VisualRecording(duration:max(time+0.01,interval),width:current.encoder.width,height:current.encoder.height,codec:codec,hardwareRequired:hardware,frames:current.frames+[entry]).validated()
        do {try await current.encoder.append(frame.buffer,time:time)} catch {if chunk === current {chunk=nil;current.encoder.cancel()};throw error}
        guard !discarded,chunk === current else {throw CancellationError()}
        current.frames.append(entry);current.lastSourceTime=frame.time
    }
    func flush() async throws {await acquire();defer {release()};guard !closed else {return};try Task.checkCancellation();try await finishCurrent(endAt:nil)}
    func boundary(at time:Double) async throws {await acquire();defer {release()};guard !closed else {return};try await finishCurrent(endAt:time)}
    func close(commit:Bool=true) async throws {
        closed=true
        if !commit {discarded=true;chunk?.encoder.cancel();pending?.encoder.cancel()}
        await acquire();defer {release()}
        if !commit {chunk=nil;return}
        try await finishCurrent(endAt:nil)
    }
    private func finishCurrent(endAt:Double?) async throws {
        guard let current=chunk else {return};chunk=nil;pending=current;defer {pending=nil}
        guard !current.frames.isEmpty else {current.encoder.cancel();return}
        let last=current.frames.last!.time
        let observed=current.lastSourceTime-current.first.time+current.interval
        let requested=endAt.map {$0-current.first.time} ?? min(observed,max(0,Date().timeIntervalSince(current.first.capturedAt)))
        let duration=min(120,max(last+1.0/600,min(observed,requested)))
        let actual=try await current.encoder.finish(duration:duration)
        guard !discarded else {throw CancellationError()}
        let visual=try VisualRecording(duration:actual,width:current.encoder.width,height:current.encoder.height,codec:codec,hardwareRequired:hardware,frames:current.frames).validated()
        var memory=Memory(id:current.id,timestamp:current.first.capturedAt,endTimestamp:current.first.capturedAt.addingTimeInterval(actual),kind:.screen,app:current.first.app,bundleID:current.first.bundle,title:current.first.title,url:current.first.url,text:visual.text,display:current.first.display,regions:current.frames[0].regions)
        memory.visualRecording=visual;memory.videoPath="video/"+current.id+".mov"
        memory.embedding=embedder?.embed(memory.searchableText);memory.embeddingModel=memory.embedding==nil ? nil:embedder?.modelID
        try gate.commit {
        let output=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath(),writable:true)
        var copied=[String](),committed=false
        defer {if !committed {for path in copied {try? output.remove(path)}}}
        _ = try current.workspace.tree.copy("clip.mov",to:output,as:memory.videoPath!);copied.append(memory.videoPath!)
        let image=CIImage(cvPixelBuffer:current.first.buffer),context=CIContext(options:[.cacheIntermediates:false])
        if !image.extent.isEmpty {
            let thumbnail=current.workspace.url.appendingPathComponent("thumbnail.jpg")
            let scale=min(1,512/max(image.extent.width,image.extent.height))
            let ci=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            if let small=context.createCGImage(ci,from:ci.extent),let destination=CGImageDestinationCreateWithURL(thumbnail as CFURL,UTType.jpeg.identifier as CFString,1,nil) {
                CGImageDestinationAddImage(destination,small,[kCGImageDestinationLossyCompressionQuality:0.65] as CFDictionary)
                if CGImageDestinationFinalize(destination) {let path="images/"+current.id+".jpg";_ = try current.workspace.tree.copy("thumbnail.jpg",to:output,as:path);memory.imagePath=path;copied.append(path)}
            }
        }
        guard !discarded else {throw CancellationError()}
        try store.insert(memory);committed=true
        }
        await onMemory(memory)
    }
}
