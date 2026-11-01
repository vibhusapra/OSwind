import SwiftUI
import AppKit

struct ClipboardContextSettingsView:View {
    @ObservedObject var model:ClipboardContextModel
    @Binding var enabled:Bool
    var body:some View {
        Section("Copied text · optional") {
            Toggle("Remember new copied text",isOn:$enabled)
            Text("Existing clipboard contents are ignored. Marked confidential, transient and remote items, files/images, and recognized secrets are skipped. App and window labels describe observed context; clipboard origin is not verified.").font(.caption).foregroundStyle(.secondary)
            if enabled {
                Text(model.status).font(.callout).textSelection(.enabled)
                HStack {
                    Button(model.running ? "Pause clipboard":"Resume clipboard") {if model.running {model.stop()}else {model.start()}}
                    Button("Ask macOS for access") {model.requestAccess()}
                    Button("Privacy settings…") {if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security") {NSWorkspace.shared.open(url)}}
                }
                Text("Asking macOS reads current text once to request permission, then discards it. Collection still starts with a later change. Background monitoring on newer macOS needs Always Allow; Accessibility is required to check window and website exclusions.").font(.caption).foregroundStyle(.secondary)
                Text("Saved this session: \(model.saved). Pause also stops clipboard capture. Polling can miss intermediate copies; unmarked background writes cannot be attributed reliably.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
