import Foundation

struct WorkflowExportFile:Codable {let path:String;let bytes:Int64;let sha256:String}
private struct WorkflowExportManifest:Codable {
    let format="OSwind independent narrated workflow"
    let info:WorkflowExportInfo
    let draft:WorkflowDraft
    let timeline:WorkflowTimeline
    let movie:WorkflowMovieReceipt
    let sourceDeletionUpdatesExport=false
    let encrypted=false
    let files:[WorkflowExportFile]
}
enum WorkflowExportFiles {
    static func write(draft:WorkflowDraft,reservations:[WorkflowFrameReservation],narration:[WorkflowNarrationResult],timeline:WorkflowTimeline,verification:WorkflowMovieReceipt,info:WorkflowExportInfo,workspace:BackupWorkspace,output:BackupWorkspace,permit:WorkflowExportPermit)throws {
        var files=[WorkflowExportFile]()
        func record(_ name:String,_ digest:BackupFileDigest) {files.append(.init(path:name,bytes:digest.bytes,sha256:digest.sha256))}
        func write(_ data:Data,_ name:String)throws {try permit.check();try output.tree.write(data,as:name);record(name,try output.tree.digest(name))}
        func copy(_ name:String)throws {try permit.check();record(name,try workspace.tree.copy(name,to:output.tree,as:name){_ in try permit.check()})}
        try copy("workflow.mp4");try copy("narration.wav");try copy("narration.txt")
        func timing(stem:String,receipt:WorkflowNarrationReceipt,script:String,combined:Bool)throws {
            let value:[String:Any] = ["model":receipt.model,"voice":receipt.voice,"speed":receipt.speed,"audio":stem+".wav","audio_seconds":receipt.audioSeconds,"sample_rate":receipt.sampleRate,"frames":receipt.frames,
                                     "verified_source_timing_sha256":receipt.timingSHA256,"script_sha256":receipt.scriptSHA256,"wav_sha256":receipt.wavSHA256,
                                     "chunkKind":combined ? "workflow-step":"local-helper-chunk","chunks":receipt.chunks.map {["start_seconds":$0.startSeconds,"end_seconds":$0.endSeconds]}]
            try write(JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),stem+".timing.json")
            let exported=try WorkflowNarrationAudio.inspect(tree:output.tree,stem:stem,script:script,scriptLimit:combined ? 12300:4000,allowRelativeAudio:true)
            guard exported.frames==receipt.frames,exported.wavSHA256==receipt.wavSHA256,exported.scriptSHA256==receipt.scriptSHA256 else {throw OSwindError.invalid("Portable narration differs from the verified source")}
        }
        try timing(stem:"narration",receipt:timeline.narration,script:draft.steps.map(\.narration).joined(separator:"\n\n"),combined:true)
        for (index,value) in narration.enumerated() {
            try copy(value.stem+".wav");try copy(value.stem+".txt")
            try timing(stem:value.stem,receipt:value.receipt,script:draft.steps[index].narration,combined:false)
            try write(reservations[index].preview.png,String(format:"step-%02d.png",index+1))
        }
        try write(Data(captions(draft:draft,timeline:timeline).utf8),"captions.vtt")
        try write(Data("OSwind narrated workflow\n\nOpen index.html or workflow.mp4. Scripts, WAVs, measured timing, captions and retained frame images are included. workflow.json contains source bindings and content hashes.\n\nThis folder is an independent, unencrypted copy. Later edits or deletion in OSwind do not change it. Timing audio paths are relative; verified_source_timing_sha256 identifies the original measured timing before that portable rewrite. The original library and credentials are not included.\n".utf8),"README.txt")
        try write(Data(html(draft:draft).utf8),"index.html")
        guard try output.tree.digest("workflow.mp4",limit:256*1024*1024).sha256==info.movieSHA256 else {throw OSwindError.unavailable("Copied movie differs from the verified output")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let manifest=WorkflowExportManifest(info:info,draft:draft,timeline:timeline,movie:verification,files:files)
        try output.tree.write(encoder.encode(manifest),as:"workflow.json")
        // All content names are fixed; step IDs, titles and scripts are data.
        for file in files {try permit.check();let actual=try output.tree.digest(file.path);guard actual.bytes==file.bytes,actual.sha256==file.sha256 else {throw OSwindError.unavailable("Workflow output changed before publication")}}
    }
    static func captions(draft:WorkflowDraft,timeline:WorkflowTimeline)->String {
        var result="WEBVTT\n\n"
        for (index,step) in draft.steps.enumerated() {
            let range=timeline.steps[index],text=step.narration.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
            result+="\(index+1)\n\(stamp(range.startFrame)) --> \(stamp(range.endFrame))\n\(escape(text))\n\n"
        }
        return result
    }
    private static func stamp(_ frames:Int64)->String {
        let milliseconds=(frames*1000+12000)/24000
        return String(format:"%02d:%02d:%02d.%03d",Int(milliseconds/3_600_000),Int(milliseconds/60_000%60),Int(milliseconds/1000%60),Int(milliseconds%1000))
    }
    static func escape(_ value:String)->String {value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;")}
    private static func html(draft:WorkflowDraft)->String {
        let steps=draft.steps.enumerated().map {index,step in "<article><img src=\""+String(format:"step-%02d.png",index+1)+"\" alt=\"Retained source for step \(index+1)\"><div><small>STEP \(index+1)</small><h2>\(escape(step.title))</h2><p>\(escape(step.narration))</p></div></article>"}.joined(separator:"\n")
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src 'self'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>\(escape(draft.title))</title><style>body{margin:0;background:#0b1220;color:#ecf1f7;font:16px/1.6 system-ui}main{max-width:1120px;margin:48px auto;padding:0 24px}h1{font-size:36px;line-height:1.2}small{color:#73d8be;letter-spacing:.08em}video{display:block;width:100%;border-radius:14px;background:#000;margin:28px 0}article{display:grid;grid-template-columns:minmax(180px,35%) 1fr;gap:28px;padding:28px 0;border-bottom:1px solid #263348}img{width:100%;border-radius:8px}h2{margin:4px 0;font-size:22px}p{white-space:pre-wrap;color:#becbdd}a{color:#8fdccb}.note{font-size:14px;color:#98aabd}@media(max-width:640px){article{grid-template-columns:1fr}main{margin-top:28px}h1{font-size:28px}}</style><main><small>OSWIND · LOCAL NARRATION</small><h1>\(escape(draft.title))</h1><p class="note">Independent, unencrypted export. Later source edits or deletion do not update this folder.</p><video controls preload="metadata" src="workflow.mp4"><track default kind="captions" srclang="en" label="Narration" src="captions.vtt"></video><p><a href="narration.txt">Narration script</a> · <a href="narration.wav">Original narration audio</a> · <a href="workflow.json">Source manifest</a></p>\(steps)</main></html>
        """
    }
}
