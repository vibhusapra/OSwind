import SwiftUI
import OSwindCore

struct PersonalSyncStatusView:View {
    @ObservedObject var model:PersonalSyncModel
    private var title:String {
        switch model.status?.phase {
        case .none:return "Preparing connection…"
        case .ready:return "Ready to sync"
        case .preparing:return "Preparing local changes"
        case .working:return "Syncing"
        case .upToDate:return "Up to date"
        case .networkPaused:return "Delivery paused · preparing locally"
        case .suspended:return "Sync suspended"
        case .needsLocalEraseReview:return "Local erase needs group review"
        case .needsReceivedErase:return "Group erase is waiting for the library owner"
        case .waitingForPolicy:return "Waiting for privacy policy"
        case .waitingForDelivery:return "Waiting for the shared folder"
        case .waitingForStorage:return "Waiting for storage"
        case .stopping:return "Stopping sync…"
        case .stopped:return "Sync stopped"
        case .failed:return "Connection needs attention"
        }
    }
    var body:some View {
        Section("Personal device sync") {
            Label(title,systemImage:model.networkPaused ? "pause.circle":"arrow.triangle.2.circlepath")
            if let status=model.status,status.withheld>0 {Text("\(status.withheld) changes are held locally by privacy policy.").font(.caption).foregroundStyle(.secondary)}
            Button(model.networkPaused ? "Resume delivery":"Pause delivery") {model.setNetworkEnabled(model.networkPaused)}
                .disabled(model.changing || model.stopping)
            Text("Pausing delivery keeps preparing local changes. Sleeping, locking or leaving this library stops processing before storage closes.").font(.caption).foregroundStyle(.secondary)
            if let error=model.error {Text(error).font(.caption).foregroundStyle(.secondary)}
        }
    }
}
