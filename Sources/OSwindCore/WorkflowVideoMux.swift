import Foundation
import AVFoundation

private final class WorkflowMediaCancellation:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    var cancelled:Bool {lock.withLock {value}}
    func cancel() {lock.withLock {value=true}}
}
enum WorkflowVideoMux {
    static func make(timeline:WorkflowTimeline,workspace:BackupWorkspace)async throws->URL {
        try Task.checkCancellation();try workspace.tree.requireRootIdentity(at:workspace.url)
        guard timeline.sampleRate==24000,timeline.frames>=2400,timeline.frames<=2_880_000,timeline.frames==timeline.narration.frames else {throw OSwindError.invalid("Invalid measured movie audio timeline")}
        guard let script=String(data:try workspace.tree.read("narration.txt",limit:12300),encoding:.utf8),
              try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:"narration",script:script,scriptLimit:12300)==timeline.narration else {throw OSwindError.unavailable("Measured narration changed before video muxing")}
        let videoDigest=try workspace.tree.digest("workflow-video.mov",limit:256*1024*1024)
        let audio=try await encodeAAC(timeline:timeline,workspace:workspace)
        let videoAsset=AVURLAsset(url:workspace.url.appendingPathComponent("workflow-video.mov")),audioAsset=AVURLAsset(url:audio)
        guard let video=try await videoAsset.loadTracks(withMediaType:.video).first,let sound=try await audioAsset.loadTracks(withMediaType:.audio).first else {throw OSwindError.invalid("Workflow video or narration track is missing")}
        let duration=CMTime(value:timeline.frames,timescale:24000),range=CMTimeRange(start:.zero,duration:duration)
        let videoDuration=try await videoAsset.load(.duration).seconds,audioDuration=try await audioAsset.load(.duration).seconds
        guard videoDuration+1.0/24000>=timeline.duration,audioDuration+1.0/24000>=timeline.duration else {throw OSwindError.invalid("A workflow track omits the end of narration")}
        let composition=AVMutableComposition()
        guard let picture=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid),let narration=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw OSwindError.unavailable("Cannot compose narrated workflow tracks")}
        try picture.insertTimeRange(range,of:video,at:.zero);try narration.insertTimeRange(range,of:sound,at:.zero)
        let url=workspace.url.appendingPathComponent("workflow.mp4")
        guard !FileManager.default.fileExists(atPath:url.path),let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough),export.supportedFileTypes.contains(.mp4) else {throw OSwindError.unavailable("Cannot prepare an H264/AAC workflow movie")}
        export.outputURL=url;export.outputFileType = .mp4;export.shouldOptimizeForNetworkUse=true
        let queue=DispatchQueue(label:"com.oswind.workflow.mux"),state=WorkflowMediaCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation {continuation in
                queue.async {
                    guard !state.cancelled else {continuation.resume();return}
                    export.exportAsynchronously {continuation.resume()}
                }
            }
        } onCancel: {
            state.cancel();queue.async {if export.status == .exporting || export.status == .waiting {export.cancelExport()}}
        }
        await barrier(queue);try Task.checkCancellation()
        guard export.status == .completed else {throw export.error ?? OSwindError.unavailable("Workflow movie export did not complete")}
        guard try workspace.tree.digest("workflow-video.mov",limit:256*1024*1024)==videoDigest,
              try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:"narration",script:script,scriptLimit:12300)==timeline.narration else {throw OSwindError.unavailable("Workflow media changed during muxing")}
        try workspace.tree.requireRootIdentity(at:workspace.url);return url
    }
    private static func encodeAAC(timeline:WorkflowTimeline,workspace:BackupWorkspace)async throws->URL {
        let source=AVURLAsset(url:workspace.url.appendingPathComponent("narration.wav"))
        guard let track=try await source.loadTracks(withMediaType:.audio).first else {throw OSwindError.invalid("Measured narration has no audio track")}
        let reader=try AVAssetReader(asset:source),output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false])
        output.alwaysCopiesSampleData=false
        let url=workspace.url.appendingPathComponent("narration.m4a"),writer=try AVAssetWriter(outputURL:url,fileType:.m4a)
        let input=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:64000]);input.expectsMediaDataInRealTime=false
        guard reader.canAdd(output),writer.canAdd(input) else {throw OSwindError.unavailable("This Mac cannot prepare local AAC narration")}
        reader.add(output);writer.add(input)
        do {
            try Task.checkCancellation()
            guard writer.startWriting(),reader.startReading() else {throw reader.error ?? writer.error ?? OSwindError.unavailable("Cannot start native narration encoding")}
            writer.startSession(atSourceTime:.zero)
            let deadline=ContinuousClock.now.advanced(by:.seconds(60));var samples:Int64=0
            while let buffer=output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let count=CMSampleBufferGetNumSamples(buffer);guard count>0,Int64(count)<=timeline.frames-samples else {throw OSwindError.invalid("Narration sample count differs from its measured timeline")}
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing,ContinuousClock.now<deadline else {throw writer.error ?? OSwindError.unavailable("Native narration encoding timed out")}
                    try await Task.sleep(for:.milliseconds(2))
                }
                guard input.append(buffer) else {throw writer.error ?? OSwindError.unavailable("Cannot append complete narration audio")}
                samples+=Int64(count)
            }
            guard reader.status == .completed,samples==timeline.frames else {throw reader.error ?? OSwindError.invalid("Native narration encoding omitted samples")}
            writer.endSession(atSourceTime:CMTime(value:timeline.frames,timescale:24000));input.markAsFinished()
            await finish(writer);try Task.checkCancellation()
            guard writer.status == .completed else {throw writer.error ?? OSwindError.unavailable("AAC narration finalization failed")}
            try workspace.tree.requireRootIdentity(at:workspace.url);return url
        }catch {
            let original=error;if reader.status == .reading {reader.cancelReading()};if writer.status == .writing {writer.cancelWriting()};throw original
        }
    }
    private static func finish(_ writer:AVAssetWriter)async {
        let queue=DispatchQueue(label:"com.oswind.workflow.audio-finish"),state=WorkflowMediaCancellation()
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
        await barrier(queue)
    }
    private static func barrier(_ queue:DispatchQueue)async {await withCheckedContinuation {continuation in queue.async {continuation.resume()}}}
}
