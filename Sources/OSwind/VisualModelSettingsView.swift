import SwiftUI
import OSwindCore

struct VisualModelSettingsView:View {
    @EnvironmentObject var m:AppModel
    var body:some View {
            Section("Visual memory · local Core ML") {
                Toggle("Enable visual memory",isOn:$m.settings.search.visual.enabled)
                Text("Find retained screenshots and replay frames by appearance, including images without OCR text. Processing stays on this Mac; no image is sent to an answer provider.").font(.caption).foregroundStyle(.secondary)
                TextField("Prepared visual model directory",text:$m.settings.search.visual.modelDirectory)
                HStack {
                    Button("Choose visual model…") {
                        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
                        if panel.runModal() == .OK,let url=panel.url {m.settings.search.visual.modelDirectory=url.path}
                    }
                    Link("Model preparation guide",destination:URL(string:"https://github.com/vibhusapra/OSwind/blob/f42736ac761b404ac73293e654670176472b2d8e/docs/VISUAL-MODELS.md#prepare-once")!)
                }
                Text("Optional Google SigLIP2 models use about 1 GB on disk. Prepare the pinned bundle once using the guide; ordinary text search needs no download.").font(.caption).foregroundStyle(.secondary)
                Picker("Visual compute",selection:$m.settings.search.visual.compute) {Text("CPU + GPU").tag(VisualCompute.cpuAndGPU);Text("CPU only").tag(VisualCompute.cpuOnly)}
                Picker("Release idle visual models",selection:$m.settings.search.visual.retention) {ForEach(NativeModelRetention.allCases,id:\.self) {Text($0.title)}}
                Toggle("Index new captures automatically",isOn:$m.settings.search.visual.automaticIndex).disabled(!m.settings.search.visual.enabled)
                HStack {
                    Button(m.visualIndexing ? "Indexing visuals…":"Build / resume visual index") {m.rebuildVisualIndex()}.disabled(m.visualIndexing || !m.settings.search.visual.enabled)
                    if m.visualIndexing || m.visualAutomaticIndexing {Button("Cancel visual indexing") {m.cancelVisualIndexing()}}
                    Button("Release visual models") {Task {await VisualEncoder.shared.unload()}}.disabled(m.visualIndexing || m.visualAutomaticIndexing)
                }
                if m.visualIndexing {ProgressView(value:m.visualIndexProgress)}
                Text(m.visualIndexStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Background work follows the search indexing power setting and pauses under serious thermal pressure. Image similarity is not a caption; open a match to inspect its recorded image or frame.").font(.caption).foregroundStyle(.secondary)
            }
    }
}
