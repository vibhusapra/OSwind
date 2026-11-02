import SwiftUI
import OSwindCore

struct PersonalSyncStatusView:View {
    @ObservedObject var model:PersonalSyncModel
    var body:some View {
        Section("Personal device sync") {PersonalSyncConnectionDetails(model:model)}
    }
}

struct PersonalSyncConnectionDetails:View {
    @ObservedObject var model:PersonalSyncModel
    private var title:String {
        switch model.status?.phase {
        case .none:return model.preparing ? "Preparing connection…":"Connection needs attention"
        case .ready:return "Ready to sync"
        case .preparing:return "Preparing local changes"
        case .working:return "Syncing"
        case .upToDate:return "Up to date"
        case .networkPaused:return "Delivery paused · preparing locally"
        case .suspended:return "Sync suspended"
        case .needsLocalEraseReview:return "Local erase needs group review"
        case .needsReceivedErase:return "Applying approved group erase"
        case .waitingForPolicy:return "Waiting for privacy policy"
        case .waitingForDelivery:return "Waiting for the shared folder"
        case .waitingForStorage:return "Waiting for storage"
        case .stopping:return "Stopping sync…"
        case .stopped:return "Sync stopped"
        case .failed:return "Connection needs attention"
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label(title,systemImage:model.networkPaused ? "pause.circle":"arrow.triangle.2.circlepath")
            if model.preparing {HStack {ProgressView().controlSize(.small);Button("Cancel setup") {model.cancelPreparation()}.disabled(model.stopping)}}
            if let status=model.status,status.withheld>0 {Text("\(status.withheld) changes are held locally by privacy policy.").font(.caption).foregroundStyle(.secondary)}
            if model.configured {
                if let folder=model.folderURL {Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                if model.ownsHistoryRetirement {
                    Toggle("Reconnect when OSwind opens this library",isOn:Binding(get:{model.reconnectOnLaunch},set:{model.setReconnectOnLaunch($0)})).disabled(model.changing || model.stopping)
                }
                Button(model.networkPaused ? "Resume delivery":"Pause delivery") {model.setNetworkEnabled(model.networkPaused)}
                    .disabled(model.changing || model.stopping)
                Text("Pausing delivery keeps preparing local changes. Sleeping, locking or leaving this library suspends processing before storage closes.").font(.caption).foregroundStyle(.secondary)
                if model.status?.phase == .needsLocalEraseReview {
                    Text("Your local history was erased. Review the exact saved decision before publishing it to your other Mac. Sync waits for this decision.").font(.callout)
                    Button("Review group erase…") {model.requestEraseReview()}.disabled(model.changing || model.stopping)
                }
            }
            if let error=model.error {Text(error).font(.caption).foregroundStyle(.secondary)}
        }
        .sheet(isPresented:Binding(get:{model.eraseReview != nil},set:{if !$0 {model.clearEraseReview()}})) {
            if let reviewed=model.eraseReview {PersonalSyncEraseReviewView(model:model,reviewed:reviewed)}
        }
    }
}

struct PersonalSyncEraseReviewView:View {
    @ObservedObject var model:PersonalSyncModel
    let reviewed:PersonalSyncEraseReview
    @State private var understood=false
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Label("Erase history across this group?",systemImage:"trash").font(.title2.weight(.semibold))
            Text("This publishes your saved local erase to these admitted Macs:")
            Text(reviewed.deviceNames.joined(separator:" · ")).font(.headline).textSelection(.enabled)
            Text("Other Macs remove their history when they observe this approved erase. This can include unsynced local changes. A sleeping or disconnected Mac applies it when sync resumes.")
            Text("Encrypted archives in your shared folder, provider versions and separate backups remain. This does not purge those copies.").foregroundStyle(.secondary)
            Toggle("I understand this removes history on the paired Macs",isOn:$understood)
            HStack {Button("Keep waiting") {model.clearEraseReview()}.keyboardShortcut(.cancelAction);Spacer()
                Button("Approve group erase",role:.destructive) {model.approveErase(reviewed)}.buttonStyle(.borderedProminent).disabled(!understood || model.changing || model.stopping || model.eraseReview != reviewed)}
        }.padding(24).frame(width:560)
    }
}
