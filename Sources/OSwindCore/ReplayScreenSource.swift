import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct ReplayScreenFrame:@unchecked Sendable {
    let buffer:CVPixelBuffer
    let time:Double
    let capturedAt:Date
}
/// The capture callback never queues unbounded pixel buffers behind OCR.
final class ReplayScreenSource:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    let frames:AsyncThrowingStream<ReplayScreenFrame,Error>
    private let continuation:AsyncThrowingStream<ReplayScreenFrame,Error>.Continuation
    private var stream:SCStream?
    private let queue=DispatchQueue(label:"com.oswind.replay.frames",qos:.utility)
    init(filter:SCContentFilter,maximumDimension:Int,interval:Double) throws {
        let pair=AsyncThrowingStream<ReplayScreenFrame,Error>.makeStream(bufferingPolicy:.bufferingNewest(1))
        frames=pair.stream;continuation=pair.continuation
        super.init()
        let rect=filter.contentRect,scale=min(2,Double(maximumDimension)/max(1,max(rect.width,rect.height)))
        let config=SCStreamConfiguration()
        config.width=max(2,Int(rect.width*scale)/2*2);config.height=max(2,Int(rect.height*scale)/2*2)
        config.minimumFrameInterval=CMTime(seconds:interval,preferredTimescale:600)
        config.queueDepth=4;config.showsCursor=false;config.pixelFormat=kCVPixelFormatType_32BGRA
        config.captureResolution = .best
        let capture=SCStream(filter:filter,configuration:config,delegate:self)
        try capture.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue);stream=capture
    }
    func start() async throws {guard let stream else {throw OSwindError.unavailable("Replay stream is closed")};try await stream.startCapture()}
    func stop() async {let capture=stream;stream=nil;continuation.finish();try? await capture?.stopCapture()}
    func stream(_ stream:SCStream,didStopWithError error:Error) {continuation.finish(throwing:error)}
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen,sampleBuffer.isValid,
              let attachments=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let raw=attachments.first?[.status] as? Int,SCFrameStatus(rawValue:raw) == .complete,
              let buffer=sampleBuffer.imageBuffer else {return}
        let time=sampleBuffer.presentationTimeStamp.seconds
        guard time.isFinite else {return}
        continuation.yield(ReplayScreenFrame(buffer:buffer,time:time,capturedAt:Date()))
    }
    deinit {continuation.finish()}
}
