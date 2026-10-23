import SwiftUI
import AppKit
import OSwindCore

struct NativeModelDownloadView:View {
    @EnvironmentObject private var model:AppModel
    @ObservedObject var setup:NativeModelSetupModel
    let kind:NativeModelKind
    private var catalog:NativeModelManifest? {try? kind.catalog()}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if let catalog {
                HStack {
                    Button("Download and use · "+ByteCountFormatter.string(fromByteCount:catalog.bytes,countStyle:.file)) {model.installNativeModel(kind)}
                    Button("Choose location…") {
                        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
                        panel.message="A versioned model folder will be installed here. Existing model folders are verified and never replaced."
                        guard panel.runModal() == .OK,let cache=panel.url else{return};model.installNativeModel(kind,cache:cache)
                    }
                }.disabled(setup.busy || (kind == .speakers && !SpeakerDiarizer.supported))
                Text("\(kind.title) · \(catalog.license) · public model files from Hugging Face").font(.caption2).foregroundStyle(.secondary)
                if setup.active==kind {
                    if let progress=setup.progress,!setup.cancelling {
                        ProgressView(value:progress.fraction)
                        Text(progress.phase+" · "+ByteCountFormatter.string(fromByteCount:progress.completedBytes,countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:progress.totalBytes,countStyle:.file)).font(.caption).foregroundStyle(.secondary)
                    }else{ProgressView().controlSize(.small)}
                    Button(setup.cancelling ? "Cancelling…":"Cancel download"){setup.cancel()}.disabled(setup.cancelling)
                }
                if let installation=setup.installed[kind] {
                    HStack {
                        Button("Use model"){model.useNativeModel(installation)}.disabled(setup.busy || model.audio.hasActiveWork || model.importingAudio)
                        Button("Verify files"){model.installNativeModel(kind,cache:installation.directory.deletingLastPathComponent(),verifyOnly:true)}.disabled(setup.busy)
                        Button("Show folder"){NSWorkspace.shared.activateFileViewerSelecting([installation.directory])}
                    }
                }
                if let status=setup.status[kind],setup.active != kind || setup.progress==nil || setup.cancelling {Text(status).font(.caption).foregroundStyle(.secondary)}
                if let error=setup.errors[kind] {Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
                if let url=URL(string:catalog.licenseURL) {Link("Model license",destination:url).font(.caption2)}
            }else {Text("The bundled native model catalog is unavailable.").font(.caption).foregroundStyle(.orange)}
        }
    }
}
