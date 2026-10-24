import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo

/// Owned by the recorder actor. Hardware is required in normal capture;
/// software encoding is an explicit fixture-only option for CI/VM tests.
final class ReplayVideoEncoder:@unchecked Sendable {
    private let finalizationQueue=DispatchQueue(label:"com.oswind.replay.finalize",qos:.utility)
    let url:URL
    let width:Int
    let height:Int
    let codec:String
    let hardwareRequired:Bool
    private let workspace:BackupWorkspace?
    private let writer:AVAssetWriter
    private let input:AVAssetWriterInput
    private var lastTime = -Double.infinity
    private var finished=false
    init(url:URL,width:Int,height:Int,frameInterval:Double,codec:String="hevc",hardwareRequired:Bool=true,workspace:BackupWorkspace?=nil) throws {
        guard (2...4096).contains(width),(2...4096).contains(height),width%2==0,height%2==0,frameInterval.isFinite,frameInterval>=0.25,frameInterval<=45,["hevc","h264"].contains(codec),!FileManager.default.fileExists(atPath:url.path) else {throw OSwindError.invalid("Invalid video dimensions, interval, codec or output")}
        self.workspace=workspace
        self.url=url;self.width=width;self.height=height;self.codec=codec;self.hardwareRequired=hardwareRequired
        writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let rate=max(0.1,1/frameInterval)
        let specification:[String:Any]=[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String:hardwareRequired,kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:hardwareRequired]
        let properties:[String:Any]=[AVVideoAverageBitRateKey:max(128000,Int(Double(width*height)*rate*0.3)),AVVideoExpectedSourceFrameRateKey:rate,AVVideoMaxKeyFrameIntervalKey:max(1,Int(rate*5)),AVVideoAllowFrameReorderingKey:false]
        let settings:[String:Any]=[AVVideoCodecKey:codec=="hevc" ? AVVideoCodecType.hevc:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoEncoderSpecificationKey:specification,AVVideoCompressionPropertiesKey:properties]
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else {throw OSwindError.unavailable("This Mac cannot encode the selected replay format")}
        input=AVAssetWriterInput(mediaType:.video,outputSettings:settings);input.expectsMediaDataInRealTime=true
        guard writer.canAdd(input) else {throw OSwindError.unavailable("Cannot prepare replay video input")}
        writer.add(input);guard writer.startWriting() else {throw writer.error ?? OSwindError.unavailable("Cannot start replay encoding")}
        writer.startSession(atSourceTime:.zero)
    }
    func append(_ buffer:CVPixelBuffer,time:Double) async throws {
        guard !finished,time.isFinite,time>=0,time>lastTime,CVPixelBufferGetWidth(buffer)==width,CVPixelBufferGetHeight(buffer)==height else {throw OSwindError.invalid("Video frame order or dimensions changed")}
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing,ContinuousClock.now<deadline else {throw writer.error ?? OSwindError.unavailable("Replay encoder could not keep up")}
            try await Task.sleep(nanoseconds:2_000_000)
        }
        try Task.checkCancellation();guard writer.status == .writing else {throw OSwindError.unavailable("Replay encoder stopped")}
        var format:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescriptionOut:&format)==noErr,let format else {throw OSwindError.unavailable("Cannot describe replay frame")}
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(seconds:time,preferredTimescale:600),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescription:format,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,let sample,input.append(sample) else {throw writer.error ?? OSwindError.unavailable("Cannot encode replay frame")}
        lastTime=time
    }
    func finish(duration:Double) async throws -> Double {
        guard !finished,lastTime.isFinite,duration.isFinite,duration>lastTime,duration<=120 else {throw OSwindError.invalid("Invalid replay end time")}
        finished=true;writer.endSession(atSourceTime:CMTime(seconds:duration,preferredTimescale:600));input.markAsFinished()
        let completion=ReplayFinishCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {continuation in
                completion.install(continuation)
                finalizationQueue.async { [self] in
                    guard completion.isPending else {return}
                    guard writer.status == .writing else {completion.resolve(.failure(writer.error ?? CancellationError()));return}
                    writer.finishWriting {completion.resolve(.success(()))}
                }
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+10) { [weak self] in
                    if completion.resolve(.failure(OSwindError.unavailable("Replay finalization timed out"))) {
                        self?.finalizationQueue.async { [weak self] in self?.writer.cancelWriting()}
                    }
                }
            }
        } onCancel: {completion.resolve(.failure(CancellationError()));self.finalizationQueue.async {self.writer.cancelWriting()}}
        try Task.checkCancellation();guard writer.status == .completed else {throw writer.error ?? OSwindError.unavailable("Replay finalization failed")}
        let actual=try await AVURLAsset(url:url).load(.duration).seconds
        guard actual.isFinite,actual>lastTime,actual<=120.01 else {throw OSwindError.invalid("Encoded replay duration differs from its frames")}
        return actual
    }
    func cancel() {finished=true;finalizationQueue.async {[self] in writer.cancelWriting()}}
    func waitForCancellation() async {await withCheckedContinuation {continuation in finalizationQueue.async {continuation.resume()}}}
    deinit {if writer.status == .writing {writer.cancelWriting()}}
}

/// Exactly-once continuation shared by the AV callback, cancellation and timeout.
private final class ReplayFinishCompletion:@unchecked Sendable {
    private let lock=NSLock()
    private var result:Result<Void,Error>?
    private var continuation:CheckedContinuation<Void,Error>?
    var isPending:Bool {lock.lock();defer {lock.unlock()};return result==nil}
    func install(_ value:CheckedContinuation<Void,Error>) {
        lock.lock()
        if let result {lock.unlock();value.resume(with:result)} else {continuation=value;lock.unlock()}
    }
    @discardableResult func resolve(_ value:Result<Void,Error>)->Bool {
        lock.lock();guard result==nil else {lock.unlock();return false}
        result=value;let pending=continuation;continuation=nil;lock.unlock();pending?.resume(with:value);return true
    }
}
