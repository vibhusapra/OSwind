import SwiftUI
import OSwindCore

struct PIIModelSettingsView:View {
    @ObservedObject var setup:PIIModelSetupModel
    var body:some View {
        Section("PII inspection · experimental local model") {
            VStack(alignment:.leading,spacing:10) {
                Text("Inspect text for personal information with a local model. Manual CLI inspection is available; learned capture protection is still in development.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(setup.busy ? "Preparing PII models…":"Prepare PII models on this Mac") {setup.start {_ in}}.disabled(setup.busy)
                    if setup.busy {Button(setup.cancelling ? "Stopping…":"Cancel preparation") {setup.cancel()}.disabled(setup.cancelling)}
                }
                if setup.busy {
                    if let progress=setup.progress,progress.totalBytes>0 {ProgressView(value:progress.fraction)} else {ProgressView().controlSize(.small)}
                    Text(setup.cancelling ? setup.status:(setup.progress?.phase ?? setup.status)).font(.caption).foregroundStyle(.secondary)
                } else if !setup.status.isEmpty {Text(setup.status).font(.caption).foregroundStyle(.secondary)}
                if let installation=setup.installation {
                    LabeledContent("Model cache",value:installation.directory.path).font(.caption).textSelection(.enabled)
                    Button("Show prepared models") {NSWorkspace.shared.open(installation.directory)}
                }
                if let error=setup.error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
                Text("About 202 MB to download and 400 MB installed; allow 1 GB of free space. Setup checks file integrity and CPU/Core ML compatibility using built-in sample text. No Python installation is needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("This experimental detector can miss personal information or hide ordinary text. Its sensitivity must be chosen explicitly for each inspection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
