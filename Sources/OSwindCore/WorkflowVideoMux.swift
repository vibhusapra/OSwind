import Foundation
import AVFoundation

private final class WorkflowMediaCancellation:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    var cancelled:Bool {lock.withLock {value}}
    func cancel() {lock.withLock {value=true}}
}
/// One MP4 writer passes through H264 and encodes PCM to AAC together. Moving a
/// separately encoded M4A through a composition lost priming in the retained
/// fixture; never infer complete speech from duration/non-silence alone.
enum WorkflowVideoMux {
    static func make(timeline:WorkflowTimeline,workspace:BackupWorkspace)async throws->URL {
        try Task.checkCancellation();try workspace.tree.requireRootIdentity(at:workspace.url)
        guard timeline.sampleRate==24000,timeline.frames>=2400,timeline.frames<=2_880_000,timeline.frames==timeline.narration.frames else {throw OSwindError.invalid("Invalid measured movie audio timeline")}
        guard let script=String(data:try workspace.tree.read("narration.txt",limit:12300),encoding:.utf8),
              try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:"narration",script:script,scriptLimit:12300)==timeline.narration else {throw OSwindError.unavailable("Measured narration changed before video muxing")}
        let videoDigest=try workspace.tree.digest("workflow-video.mov",limit:256*1024*1024)
        let videoAsset=AVURLAsset(url:workspace.url.appendingPathComponent("workflow-video.mov")),audioAsset=AVURLAsset(url:workspace.url.appendingPathComponent("narration.wav"))
        guard let video=try await videoAsset.loadTracks(withMediaType:.video).first,let sound=try await audioAsset.loadTracks(withMediaType:.audio).first else {throw OSwindError.invalid("Workflow video or narration track is missing")}
        let formats=try await video.load(.formatDescriptions)
        guard formats.count==1,CMFormatDescriptionGetMediaSubType(formats[0])==kCMVideoCodecType_H264 else {throw OSwindError.invalid("Workflow source video must be H264")}
        let videoReader=try AVAssetReader(asset:videoAsset),audioReader=try AVAssetReader(asset:audioAsset)
        let videoOutput=AVAssetReaderTrackOutput(track:video,outputSettings:nil),audioOutput=AVAssetReaderTrackOutput(track:sound,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false])
        videoOutput.alwaysCopiesSampleData=false;audioOutput.alwaysCopiesSampleData=false
        let url=workspace.url.appendingPathComponent("workflow.mp4"),writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        writer.shouldOptimizeForNetworkUse=true
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:formats[0]),audioInput=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:64000])
        videoInput.expectsMediaDataInRealTime=false;audioInput.expectsMediaDataInRealTime=false
        guard videoReader.canAdd(videoOutput),audioReader.canAdd(audioOutput),writer.canAdd(videoInput),writer.canAdd(audioInput) else {throw OSwindError.unavailable("This Mac cannot prepare H264/AAC workflow output")}
        videoReader.add(videoOutput);audioReader.add(audioOutput);writer.add(videoInput);writer.add(audioInput)
        do {
            try Task.checkCancellation()
            guard writer.startWriting(),videoReader.startReading(),audioReader.startReading() else {throw writer.error ?? videoReader.error ?? audioReader.error ?? OSwindError.unavailable("Cannot start native workflow muxing")}
            writer.startSession(atSourceTime:.zero)
            func nextMedia(_ output:AVAssetReaderTrackOutput)throws->CMSampleBuffer? {
                var markers=0
                while let value=output.copyNextSampleBuffer() {
                    if CMSampleBufferGetNumSamples(value)>0 {return value}
                    markers+=1
                    guard markers<=1024,CMSampleBufferGetTotalSampleSize(value)==0 else {throw OSwindError.invalid("Invalid workflow media boundary markers")}
                    // Empty edit/drain markers may have invalid PTS. Consume
                    // them before timestamp ordering, so EOF reaches the writer.
                }
                return nil
            }
            var picture=try nextMedia(videoOutput),audio=try nextMedia(audioOutput),samples:Int64=0,images=0
            var videoFinished=false,audioFinished=false
            func finishExhaustedInputs()throws {
                // Mark EOF immediately. Waiting until both streams end can
                // stall AAC while the writer waits for another still image.
                if picture==nil,!videoFinished {
                    guard videoReader.status == .completed else {throw videoReader.error ?? OSwindError.invalid("Workflow video ended before reader completion")}
                    videoInput.markAsFinished();videoFinished=true
                }
                if audio==nil,!audioFinished {
                    guard audioReader.status == .completed else {throw audioReader.error ?? OSwindError.invalid("Workflow audio ended before reader completion")}
                    audioInput.markAsFinished();audioFinished=true
                }
            }
            try finishExhaustedInputs()
            let deadline=ContinuousClock.now.advanced(by:.seconds(60))
            while picture != nil || audio != nil {
                try Task.checkCancellation()
                let isVideo:Bool
                if let picture {isVideo=audio.map {CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(picture),CMSampleBufferGetPresentationTimeStamp($0))<=0} ?? true}else{isVideo=false}
                guard let buffer=isVideo ? picture:audio else {throw OSwindError.invalid("Workflow media buffer disappeared")}
                let input=isVideo ? videoInput:audioInput,pts=CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard pts.isFinite,pts>=0,pts<timeline.duration+1.0/600 else {throw OSwindError.invalid("Workflow sample timestamp exceeds narration")}
                if !isVideo {
                    let count=CMSampleBufferGetNumSamples(buffer)
                    guard count>0,Int64(count)<=timeline.frames-samples else {throw OSwindError.invalid("Narration sample count differs from its measured timeline")}
                    samples+=Int64(count)
                }
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing,ContinuousClock.now<deadline else {throw writer.error ?? OSwindError.unavailable("Native workflow encoding timed out (\(isVideo ? "video":"audio"), \(images) images, \(samples) PCM frames)")}
                    try await Task.sleep(for:.milliseconds(2))
                }
                guard input.append(buffer) else {throw writer.error ?? OSwindError.unavailable("Cannot append complete workflow media")}
                if isVideo {images+=1;picture=try nextMedia(videoOutput)}else{audio=try nextMedia(audioOutput)}
                try finishExhaustedInputs()
            }
            guard videoReader.status == .completed,audioReader.status == .completed,samples==timeline.frames,images==timeline.steps.count else {throw videoReader.error ?? audioReader.error ?? OSwindError.invalid("Native workflow muxing omitted source media")}
            writer.endSession(atSourceTime:CMTime(value:timeline.frames,timescale:24000))
            await finish(writer);try Task.checkCancellation()
            guard writer.status == .completed else {throw writer.error ?? OSwindError.unavailable("Workflow movie finalization failed")}
            guard try workspace.tree.digest("workflow-video.mov",limit:256*1024*1024)==videoDigest,
                  try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:"narration",script:script,scriptLimit:12300)==timeline.narration else {throw OSwindError.unavailable("Workflow media changed during muxing")}
            try workspace.tree.requireRootIdentity(at:workspace.url);return url
        }catch {
            let original=error
            for reader in [videoReader,audioReader] where reader.status == .reading {reader.cancelReading()}
            if writer.status == .writing {writer.cancelWriting()};throw original
        }
    }
    private static func finish(_ writer:AVAssetWriter)async {
        let queue=DispatchQueue(label:"com.oswind.workflow.movie-finish"),state=WorkflowMediaCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation {continuation in
                queue.async {
                    if state.cancelled || writer.status != .writing {
                        if writer.status == .writing {writer.cancelWriting()};continuation.resume();return
                    }
                    writer.finishWriting {continuation.resume()}
                }
            }
        } onCancel: {state.cancel();queue.async {if writer.status == .writing {writer.cancelWriting()}}}
        await withCheckedContinuation {continuation in queue.async {continuation.resume()}}
    }
}
