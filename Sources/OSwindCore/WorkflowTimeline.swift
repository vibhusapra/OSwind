import Foundation
import AVFoundation

public struct WorkflowStepTiming:Codable,Equatable,Sendable {
    public let stepID:UUID
    public let startFrame:Int64
    public let endFrame:Int64
    public var startSeconds:Double {Double(startFrame)/24000}
    public var endSeconds:Double {Double(endFrame)/24000}
}
public struct WorkflowTimeline:Codable,Sendable {
    public let draftRevision:String
    public let sampleRate:Int
    public let frames:Int64
    public let steps:[WorkflowStepTiming]
    public let narration:WorkflowNarrationReceipt
    public var duration:Double {Double(frames)/Double(sampleRate)}
}

enum LocalWorkflowTimeline {
    static func combine(draft:WorkflowDraft,narrations:[WorkflowNarrationResult],workspace:BackupWorkspace)throws->WorkflowTimeline {
        let draft=try draft.validated(),maximum=Int64(WorkflowDraft.maximumDuration*24000)
        guard narrations.count==draft.steps.count else {throw OSwindError.invalid("Every workflow step needs measured narration")}
        var total:Int64=0,steps=[WorkflowStepTiming]()
        for (index,value) in narrations.enumerated() {
            guard value.stem==String(format:"step-%02d-narration",index+1),value.receipt.frames>=2400,value.receipt.frames<=maximum,
                  total<=maximum-value.receipt.frames,value.receipt.scriptSHA256==WorkflowDraft.digest(Data(draft.steps[index].narration.utf8)) else {throw OSwindError.invalid("Workflow narration changed or exceeds 120 seconds")}
            let current=try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:value.stem,script:draft.steps[index].narration)
            guard current==value.receipt else {throw OSwindError.unavailable("A measured narration file changed before combining")}
            steps.append(.init(stepID:draft.steps[index].id,startFrame:total,endFrame:total+current.frames));total+=current.frames
        }
        let script=draft.steps.map(\.narration).joined(separator:"\n\n")
        try workspace.tree.write(Data(script.utf8),as:"narration.txt")
        var header=WAV.data(samples:[],sampleRate:24000),size=UInt32(total*2).littleEndian,riff=UInt32(total*2+36).littleEndian
        withUnsafeBytes(of:&riff){header.replaceSubrange(4..<8,with:$0)};withUnsafeBytes(of:&size){header.replaceSubrange(40..<44,with:$0)}
        var copied:Int64=0
        try workspace.tree.withNewFile("narration.wav") {descriptor in
            let output=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
            try output.write(contentsOf:header)
            for value in narrations {
                try Task.checkCancellation()
                let file=try AVAudioFile(forReading:workspace.url.appendingPathComponent(value.stem+".wav"),commonFormat:.pcmFormatInt16,interleaved:false)
                guard file.length==value.receipt.frames,let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096) else {throw OSwindError.invalid("Cannot read complete narration PCM")}
                var count:Int64=0
                while file.framePosition<file.length {
                    try Task.checkCancellation();try file.read(into:buffer,frameCount:4096)
                    guard buffer.frameLength>0,let pcm=buffer.int16ChannelData?[0] else {throw OSwindError.invalid("Narration PCM is truncated")}
                    let bytes=Data(bytes:pcm,count:Int(buffer.frameLength)*2)
                    try output.write(contentsOf:bytes);count+=Int64(buffer.frameLength)
                    guard count<=value.receipt.frames else {throw OSwindError.invalid("Narration PCM length changed")}
                }
                guard count==value.receipt.frames else {throw OSwindError.invalid("Narration PCM is incomplete")}
                copied+=count
            }
            guard copied==total else {throw OSwindError.invalid("Combined narration omitted audio frames")}
            try output.synchronize()
        }
        // Recheck the inputs after streaming as well. Helper workers have
        // already joined; detected changes refuse the combined result.
        for (index,value) in narrations.enumerated() {
            guard try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:value.stem,script:draft.steps[index].narration)==value.receipt else {throw OSwindError.unavailable("Narration changed during combination")}
        }
        let metadata:[String:Any] = ["model":"mlx-community/Kokoro-82M-bf16","voice":"af_heart","speed":1.0,"audio":workspace.url.appendingPathComponent("narration.wav").path,"audio_seconds":Double(total)/24000,
                                    "chunkKind":"workflow-step","chunks":steps.map {["start_seconds":$0.startSeconds,"end_seconds":$0.endSeconds]}]
        try workspace.tree.write(JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys),as:"narration.timing.json")
        let receipt=try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:"narration",script:script,scriptLimit:12300)
        guard receipt.frames==total else {throw OSwindError.invalid("Combined narration duration differs from its steps")}
        return .init(draftRevision:try draft.revision,sampleRate:24000,frames:total,steps:steps,narration:receipt)
    }
}
