import SwiftUI
import OSwindCore

struct VisualModelSettingsView:View {
    @EnvironmentObject var m:AppModel
    var body:some View {
            Section("Visual memory · local Core ML") {
                Toggle("Enable visual memory",isOn:$m.settings.search.visual.enabled)
                Text("Find retained screenshots and replay frames by appearance, including images without OCR text. Processing stays on this Mac; no image is sent to an answer provider.").font(.caption).foregroundStyle(.secondary)
                VisualModelPrepareView(setup:m.visualModelSetup,completion:m.selectPreparedVisualModel)
                TextField("Prepared visual model directory",text:$m.settings.search.visual.modelDirectory).disabled(m.visualModelSetup.busy)
                HStack {
                    Button("Choose visual model…") {
                        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
                        if panel.runModal() == .OK,let url=panel.url {m.settings.search.visual.modelDirectory=url.path}
                    }.disabled(m.visualModelSetup.busy)
                    Link("Model preparation guide",destination:URL(string:"https://github.com/vibhusapra/OSwind/blob/codex/visual-model-preparation/docs/VISUAL-MODELS.md#prepare-once")!)
                }
                Text("The prepared Google SigLIP2 bundle uses about 1 GB. Preparing it locally also caches public weights and tools; allow 10 GB of free space. Ordinary text search needs no download.").font(.caption).foregroundStyle(.secondary)
                Picker("Visual compute",selection:$m.settings.search.visual.compute) {Text("CPU + GPU").tag(VisualCompute.cpuAndGPU);Text("CPU only").tag(VisualCompute.cpuOnly)}
                Picker("Release idle visual models",selection:$m.settings.search.visual.retention) {ForEach(NativeModelRetention.allCases,id:\.self) {Text($0.title)}}
                Toggle("Index new captures automatically",isOn:$m.settings.search.visual.automaticIndex).disabled(!m.settings.search.visual.enabled)
                HStack {
                    Button(m.visualIndexing ? "Indexing visuals…":"Build / resume visual index") {m.rebuildVisualIndex()}.disabled(m.visualIndexing || !m.settings.search.visual.enabled || m.visualModelSetup.busy)
                    if m.visualIndexing || m.visualAutomaticIndexing {Button("Cancel visual indexing") {m.cancelVisualIndexing()}}
                    Button("Release visual models") {Task {await VisualEncoder.shared.unload()}}.disabled(m.visualIndexing || m.visualAutomaticIndexing || m.visualModelSetup.busy)
                }
                if m.visualIndexing {ProgressView(value:m.visualIndexProgress)}
                Text(m.visualIndexStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Background work follows the search indexing power setting and pauses under serious thermal pressure. Image similarity is not a caption; open a match to inspect its recorded image or frame.").font(.caption).foregroundStyle(.secondary)
            }
    }
}

struct VisualModelPrepareView:View {
    @ObservedObject var setup:VisualModelSetupModel
    let completion:(VisualModelInstallation)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Button(setup.busy ? "Preparing local visual models…":"Prepare visual model on this Mac") {setup.start(completion:completion)}.disabled(setup.busy)
                if setup.busy {Button(setup.cancelling ? "Stopping…":"Cancel preparation") {setup.cancel()}.disabled(setup.cancelling)}
            }
            if setup.busy {
                if let progress=setup.progress,progress.totalBytes>0 {ProgressView(value:progress.fraction)} else {ProgressView().controlSize(.small)}
                Text(setup.progress?.phase ?? setup.status).font(.caption).foregroundStyle(.secondary)
            } else if !setup.status.isEmpty {Text(setup.status).font(.caption).foregroundStyle(.secondary)}
            if let error=setup.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                let details=VisualModelPreparation.defaultCache.appendingPathComponent("last-visual-setup-error.json")
                if FileManager.default.fileExists(atPath:details.path) {Button("Show setup details") {NSWorkspace.shared.open(details)}}
            }
            if ProcessInfo.processInfo.physicalMemory<16*1024*1024*1024 {Text("Local preparation can use about 9 GB of RAM. A bundle prepared on another Mac can be selected below.").font(.caption).foregroundStyle(.secondary)}
            Text("Downloads public model files and local preparation tools, then checks CPU/GPU results before installation. First setup can take several minutes. Your recorded history is not used. Already prepared bundles can be chosen below.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
