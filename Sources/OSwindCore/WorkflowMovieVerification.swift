import Foundation
import AVFoundation

public struct WorkflowMovieReceipt:Codable,Sendable {
    public let videoCodec:String
    public let audioCodec:String
    public let width:Int
    public let height:Int
    public let duration:Double
    public let decodedAudioFrames:Int64
    public let decodedAudioRMS:Double
    public let decodedAudioPeak:Double
    public let sourceAudioCorrelation:Double
    public let aacPrimingFrames:UInt64
    public let aacTrailingFrames:UInt64
}
enum WorkflowMovieVerification {
    static func inspect(url:URL,timeline:WorkflowTimeline,narration:URL)async throws->WorkflowMovieReceipt {
        try Task.checkCancellation()
        guard timeline.sampleRate==24000,timeline.frames>=2400,timeline.frames<=2_880_000 else {throw OSwindError.invalid("Invalid narration verification timeline")}
        let asset=AVURLAsset(url:url),videos=try await asset.loadTracks(withMediaType:.video),sounds=try await asset.loadTracks(withMediaType:.audio),duration=try await asset.load(.duration).seconds
        guard videos.count==1,sounds.count==1,duration.isFinite,abs(duration-timeline.duration)<=1.0/24000 else {throw OSwindError.invalid("Workflow movie tracks or duration are incomplete")}
        let video=videos[0],sound=sounds[0],size=try await video.load(.naturalSize),videoFormats=try await video.load(.formatDescriptions),audioFormats=try await sound.load(.formatDescriptions)
        guard size.width==1280,size.height==720,videoFormats.count==1,audioFormats.count==1,
              CMFormatDescriptionGetMediaSubType(videoFormats[0])==kCMVideoCodecType_H264,CMFormatDescriptionGetMediaSubType(audioFormats[0])==kAudioFormatMPEG4AAC else {throw OSwindError.invalid("Workflow movie must contain 1280×720 H264 and AAC narration")}
        guard let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(audioFormats[0]),asbd.pointee.mSampleRate==24000,asbd.pointee.mChannelsPerFrame==1 else {throw OSwindError.invalid("Unexpected workflow AAC audio format")}
        let edit=try WorkflowAACEdit.inspect(url:url,frames:timeline.frames,packetFrames:asbd.pointee.mFramesPerPacket)
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:sound,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else {throw OSwindError.unavailable("Cannot verify decoded workflow narration")}
        reader.add(output);reader.timeRange=CMTimeRange(start:.zero,duration:CMTime(value:timeline.frames,timescale:24000))
        let original=try AVAudioFile(forReading:narration,commonFormat:.pcmFormatFloat32,interleaved:false)
        guard original.length==timeline.frames,original.processingFormat.sampleRate==24000,original.processingFormat.channelCount==1,
              let originalBuffer=AVAudioPCMBuffer(pcmFormat:original.processingFormat,frameCapacity:AVAudioFrameCount(timeline.frames)) else {throw OSwindError.invalid("Source narration does not match the measured timeline")}
        try original.read(into:originalBuffer,frameCount:AVAudioFrameCount(timeline.frames))
        guard Int64(originalBuffer.frameLength)==timeline.frames,let originalSamples=originalBuffer.floatChannelData?[0] else {throw OSwindError.invalid("Source narration is truncated")}
        defer {withExtendedLifetime(originalBuffer) {}}
        guard reader.startReading() else {throw reader.error ?? OSwindError.unavailable("Cannot start workflow narration verification")}
        var frames:Int64=0,sum=0.0,peak=0.0,sourceEnergy=0.0,cross=0.0
        do {
            while let sample=output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let count=CMSampleBufferGetNumSamples(sample),pts=CMSampleBufferGetPresentationTimeStamp(sample)
                guard count>0,count<=16384,pts.seconds.isFinite,let block=CMSampleBufferGetDataBuffer(sample),CMBlockBufferGetDataLength(block)==count*4 else {throw OSwindError.invalid("Invalid decoded workflow audio buffer")}
                let start=CMTimeConvertScale(pts,timescale:24000,method:.roundHalfAwayFromZero).value
                guard start>=(-4096),start<=timeline.frames+4096 else {throw OSwindError.invalid("Decoded narration timestamps exceed their bounds")}
                var values=[Float](repeating:0,count:count)
                let status=values.withUnsafeMutableBufferPointer {CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count*4,destination:$0.baseAddress!)}
                guard status==kCMBlockBufferNoErr else {throw OSwindError.invalid("Cannot inspect complete decoded narration samples")}
                for (index,value) in values.enumerated() {
                    let position=start+Int64(index)
                    if position<0 || position>=timeline.frames {continue} // AAC preroll/padding is outside the authored range.
                    guard position==frames,value.isFinite,abs(value)<=2 else {throw OSwindError.invalid("Decoded narration has a gap, overlap or invalid samples")}
                    let value=Double(value),expected=Double(originalSamples[Int(position)])
                    guard expected.isFinite else {throw OSwindError.invalid("Source narration contains invalid PCM")}
                    sum+=value*value;sourceEnergy+=expected*expected;cross+=value*expected;peak=max(peak,abs(value));frames+=1
                }
            }
            guard reader.status == .completed,frames==timeline.frames else {throw reader.error ?? OSwindError.invalid("Decoded movie omits narration frames")}
            let rms=sqrt(sum/Double(max(1,frames)))
            guard rms>0.00001,peak>0.0001 else {throw OSwindError.invalid("Workflow movie narration is silent")}
            let correlation=cross/sqrt(sourceEnergy*sum)
            guard correlation.isFinite,correlation>=0.95 else {throw OSwindError.invalid("Decoded narration does not align with the complete source audio")}
            try Task.checkCancellation()
            return .init(videoCodec:"h264",audioCodec:"aac",width:1280,height:720,duration:duration,decodedAudioFrames:frames,decodedAudioRMS:rms,decodedAudioPeak:peak,sourceAudioCorrelation:correlation,aacPrimingFrames:edit.primingFrames,aacTrailingFrames:edit.trailingFrames)
        }catch {let original=error;if reader.status == .reading {reader.cancelReading()};throw original}
    }
}
