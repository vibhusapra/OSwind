import SwiftUI
import OSwindCore

struct PIIModelSettingsView:View {
    @ObservedObject var setup:PIIModelSetupModel
    @Binding var configuration:PIIImportConfiguration
    var body:some View {
        Section("PII inspection · experimental local model") {
            VStack(alignment:.leading,spacing:10) {
                Text("Inspect text for personal information with a local model. Optional masking is available for new JSON and Limitless imports and CLI collectors. Capture and egress protection are still in development.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Additional PII masking for new imports",isOn:$configuration.enabled)
                if configuration.enabled {
                    Picker("Compute",selection:$configuration.compute) {Text("Core ML · Mac acceleration").tag(PIIComputePolicy.coreML);Text("CPU").tag(PIIComputePolicy.cpu)}
                    HStack {Text("Sensitivity threshold");Slider(value:$configuration.threshold,in:0.1...0.9,step:0.05);Text(configuration.threshold,format:.number.precision(.fractionLength(2))).monospacedDigit()}
                    Text("Lower thresholds hide more text. No threshold has met our privacy acceptance target. Missing models, oversized sources, cancellation or invalid results refuse the entire batch; there is no unscanned fallback.").font(.caption).foregroundStyle(.secondary)
                }
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
                Text("This experimental detector can miss personal information or hide ordinary text. Imports stay off by default and use additional original-source pattern checks even when regular pattern redaction is off. Only future imports are affected; existing history and retained media are not rescanned.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
