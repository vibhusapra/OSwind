import Foundation
import Darwin

struct WorkflowNarrationEnvironment:Sendable {
    var run:@Sendable (URL,[String],[String:String],[Int32]) async throws->Void
    static func production(guardian:URL?=PreparationProcess.guardian)->Self {
        Self {helper,arguments,environment,keepAlive in
            guard let guardian,FileManager.default.isExecutableFile(atPath:guardian.path) else {throw OSwindError.unavailable("Use the packaged OSwind preparation helper for local narration")}
            let result=try await PreparationProcess.run(helper,arguments,environment:environment,timeout:300,outputLimit:64*1024,guardian:guardian,keepAlive:keepAlive)
            guard result.status==0 else {throw OSwindError.unavailable("Local Kokoro narration failed. Check the installed helper and cached model.")}
        }
    }
}
struct WorkflowNarrationResult:Sendable {
    let stem:String
    let receipt:WorkflowNarrationReceipt
}
enum LocalWorkflowNarrator {
    static var defaultHelper:URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kokoro-narrate")}
    static func generate(script:String,step:Int,workspace:BackupWorkspace,helper:URL=defaultHelper,environment:WorkflowNarrationEnvironment = .production()) async throws->WorkflowNarrationResult {
        try Task.checkCancellation()
        guard (1...WorkflowDraft.maximumSteps).contains(step),!script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,script.utf8.count<=4000,!script.utf8.contains(0),
              helper.isFileURL,helper.path.hasPrefix("/"),helper.path.utf8.count<=4096,!helper.path.utf8.contains(0),FileManager.default.isExecutableFile(atPath:helper.path) else {throw OSwindError.unavailable("Choose the installed local Kokoro narration helper and a bounded step script")}
        try workspace.tree.requireRootIdentity(at:workspace.url)
        let stem=String(format:"step-%02d-narration",step),input=workspace.url.appendingPathComponent(stem+".txt"),output=workspace.url.appendingPathComponent(stem+".wav")
        try workspace.tree.write(Data(script.utf8),as:stem+".txt")
        let lifetime=try workspace.retainedLifetimeDescriptor();defer {close(lifetime)}
        let variables=["HOME":FileManager.default.homeDirectoryForCurrentUser.path,"PATH":"/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8",
                       "HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","HF_HUB_DISABLE_TELEMETRY":"1","DO_NOT_TRACK":"1","PYTHONDONTWRITEBYTECODE":"1","TMPDIR":workspace.url.path+"/"]
        try await environment.run(helper,["--input",input.path,"--output",output.path,"--voice","af_heart","--speed","1.0"],variables,[lifetime])
        try Task.checkCancellation();try workspace.tree.requireRootIdentity(at:workspace.url)
        // The helper creates files under a private directory. Tighten the
        // generated regular members before retaining/exporting them as well.
        for name in [stem+".wav",stem+".timing.json"] {
            try workspace.tree.withFile(name) {file,_ in guard fchmod(file,0o600)==0 else {throw OSwindError.unavailable("Cannot protect generated narration")}}
        }
        return .init(stem:stem,receipt:try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:stem,script:script))
    }
}
