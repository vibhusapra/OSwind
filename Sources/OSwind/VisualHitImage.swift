import SwiftUI
import OSwindCore

struct VisualHitImage:View {
    @EnvironmentObject var m:AppModel
    let hit:SearchHit
    @State private var image:NSImage?
    @State private var unavailable=false
    var body:some View {
        ZStack {
            if let image {Image(nsImage:image).resizable().aspectRatio(contentMode:.fill)}
            else if unavailable {Label("Source changed or unavailable",systemImage:"photo.badge.exclamationmark").font(.caption).foregroundStyle(.secondary)}
            else {ProgressView().controlSize(.small)}
        }.frame(height:150).frame(maxWidth:.infinity).clipped()
        .accessibilityLabel(hit.visual?.frameTime.map {"Matched replay frame at \($0.formatted(.number.precision(.fractionLength(1)))) seconds"} ?? "Matched image")
        .task(id:hit.visual) {
            image=nil;unavailable=false
            guard let match=hit.visual else {return}
            let store=m.store,memory=hit.memory,worker=Task.detached(priority:.utility) {try await store.visualPreview(memory:memory,match:match)}
            do {
                let result=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
                try Task.checkCancellation();image=NSImage(cgImage:result,size:.zero)
            } catch is CancellationError {} catch {unavailable=true}
        }.onDisappear {image=nil}
    }
}
