import Foundation
import AVFoundation
import Darwin

public struct WorkflowNarrationChunk:Codable,Equatable,Sendable {
    public let startSeconds:Double
    public let endSeconds:Double
}
public struct WorkflowNarrationReceipt:Codable,Equatable,Sendable {
    public let model:String
    public let voice:String
    public let speed:Double
    public let sampleRate:Int
    public let frames:Int64
    public let audioSeconds:Double
    public let rms:Double
    public let peak:Double
    public let scriptSHA256:String
    public let wavSHA256:String
    public let timingSHA256:String
    public let chunks:[WorkflowNarrationChunk]
}

/// Checks the measured file, not just a helper's success status. A later mux
/// must preserve all these audio frames and independently verify its output.
enum WorkflowNarrationAudio {
    static let sampleRate=24000
    private struct Timing:Decodable {
        var model:String,voice:String,audio:String
        var speed:Double,audio_seconds:Double
        var chunks:[Chunk]
        struct Chunk:Decodable {var start_seconds:Double,end_seconds:Double}
    }
    static func inspect(tree:BackupFileTree,stem:String,script:String,scriptLimit:Int=4000,allowRelativeAudio:Bool=false)throws->WorkflowNarrationReceipt {
        try Task.checkCancellation()
        guard !stem.isEmpty,stem.utf8.count<=64,stem.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==45}),
              (1...12300).contains(scriptLimit),!script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,script.utf8.count<=scriptLimit,!script.utf8.contains(0) else {throw OSwindError.invalid("Invalid narration script or member name")}
        try tree.requireRootIdentity(at:tree.root)
        let expectedScript=Data(script.utf8),scriptName=stem+".txt",wavName=stem+".wav",timingName=stem+".timing.json"
        guard try tree.read(scriptName,limit:scriptLimit)==expectedScript else {throw OSwindError.unavailable("The reviewed narration script changed")}
        let timingBytes=try tree.read(timingName,limit:64*1024),timing=try JSONDecoder().decode(Timing.self,from:timingBytes)
        let url=tree.root.appendingPathComponent(wavName)
        let audioMatches:Bool
        if allowRelativeAudio,timing.audio==wavName {audioMatches=true}
        else if !timing.audio.utf8.contains(0),timing.audio.hasPrefix("/") {audioMatches=try canonical(URL(fileURLWithPath:timing.audio))==canonical(url)}
        else {audioMatches=false}
        guard timing.model=="mlx-community/Kokoro-82M-bf16",timing.voice=="af_heart",timing.speed==1,
              timing.audio_seconds.isFinite,timing.audio_seconds>0,timing.audio_seconds<=WorkflowDraft.maximumDuration,
              audioMatches else {throw OSwindError.invalid("Narration receipt does not match the selected local stock voice and output")}
        let before=try tree.digest(wavName,limit:8*1024*1024)
        let audio=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false),format=audio.fileFormat.streamDescription.pointee
        guard format.mFormatID==kAudioFormatLinearPCM,format.mSampleRate==Double(sampleRate),format.mChannelsPerFrame==1,format.mBitsPerChannel==16,
              format.mFormatFlags & kAudioFormatFlagIsFloat==0,format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              audio.length>=2400,audio.length<=Int64(Double(sampleRate)*WorkflowDraft.maximumDuration),
              let buffer=AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:4096) else {throw OSwindError.invalid("Narration must be bounded 24 kHz mono PCM16 audio")}
        var count:Int64=0,sum=0.0,peak=0.0
        while audio.framePosition<audio.length {
            try Task.checkCancellation();try audio.read(into:buffer,frameCount:4096)
            guard buffer.frameLength>0,let values=buffer.floatChannelData?[0] else {throw OSwindError.invalid("Narration audio is truncated")}
            for index in 0..<Int(buffer.frameLength) {
                let value=Double(values[index])
                guard value.isFinite,abs(value)<=1.00001 else {throw OSwindError.invalid("Narration contains invalid samples")}
                sum+=value*value;peak=max(peak,abs(value))
            }
            count+=Int64(buffer.frameLength)
            guard count<=Int64(Double(sampleRate)*WorkflowDraft.maximumDuration) else {throw OSwindError.invalid("Narration exceeds the video duration budget")}
        }
        let duration=Double(count)/Double(sampleRate),rms=sqrt(sum/Double(max(1,count))),tolerance=1.0/Double(sampleRate)
        guard count==audio.length,rms>0.00001,peak>0.0001,abs(duration-timing.audio_seconds)<=tolerance,
              !timing.chunks.isEmpty,timing.chunks.count<=256 else {throw OSwindError.invalid("Narration is silent, incomplete or differs from its measured timing")}
        var previous=0.0,chunks=[WorkflowNarrationChunk]()
        for chunk in timing.chunks {
            guard chunk.start_seconds.isFinite,chunk.end_seconds.isFinite,chunk.start_seconds>=0,chunk.end_seconds>chunk.start_seconds,
                  abs(chunk.start_seconds-previous)<=tolerance,chunk.end_seconds<=duration+tolerance else {throw OSwindError.invalid("Narration timing chunks have gaps, overlap or invalid bounds")}
            chunks.append(.init(startSeconds:chunk.start_seconds,endSeconds:chunk.end_seconds));previous=chunk.end_seconds
        }
        guard abs(previous-duration)<=tolerance,try tree.digest(wavName,limit:8*1024*1024)==before,
              try tree.read(scriptName,limit:scriptLimit)==expectedScript,try tree.read(timingName,limit:64*1024)==timingBytes else {throw OSwindError.unavailable("Narration files changed during verification")}
        try tree.requireRootIdentity(at:tree.root);try Task.checkCancellation()
        return .init(model:timing.model,voice:timing.voice,speed:timing.speed,sampleRate:sampleRate,frames:count,audioSeconds:duration,rms:rms,peak:peak,
                     scriptSHA256:WorkflowDraft.digest(expectedScript),wavSHA256:before.sha256,timingSHA256:WorkflowDraft.digest(timingBytes),chunks:chunks)
    }
    private static func canonical(_ url:URL)throws->String {
        guard let value=realpath(url.path,nil) else {throw OSwindError.unavailable("Narration output is unavailable")}
        defer {free(value)};return String(cString:value)
    }
}
