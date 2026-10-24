import SwiftUI
import OSwindCore

@MainActor final class RecapDetailModel:ObservableObject {
    @Published private(set) var sources=[RecapSourceCard]()
    @Published private(set) var error:String?
    private var task:Task<Void,Never>?
    deinit {task?.cancel()}
    func stop() {task?.cancel();task=nil}
    func watch(_ memory:Memory,store:MemoryStore,interval:UInt64=2_000_000_000,onInvalidated:@escaping ()->Void) {
        stop();sources=[];error=nil
        task=Task { [weak self] in
            var loaded=false
            while !Task.isCancelled {
                do {
                    let valid=try await Task.detached(priority:.utility) {let current=try store.get(memory.id);return current?.evidenceHash==memory.evidenceHash && current?.recap==memory.recap}.value
                    guard !Task.isCancelled else {return}
                    guard valid else {self?.sources=[];self?.error="This recap changed or its original evidence was removed.";onInvalidated();return}
                    if !loaded {
                        let evidence=try await Task.detached(priority:.utility) {try store.recapSourceCards(memory.id)}.value
                        guard !Task.isCancelled else {return};self?.sources=evidence;loaded=true
                    }
                    try await Task.sleep(nanoseconds:interval)
                } catch is CancellationError {return}
                catch {guard !Task.isCancelled else {return};self?.sources=[];self?.error=error.localizedDescription;return}
            }
        }
    }
}
struct RecapEvidenceView:View {
    @EnvironmentObject var m:AppModel
    let memory:Memory
    @StateObject private var detail=RecapDetailModel()
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            if let recap=memory.recap {
                Label("Source-linked recap",systemImage:"link").font(.headline)
                Text("AI-generated with \(recap.provider). Its date records when saved. Removing or revising an original removes this live copy and any recaps derived from it.").font(.caption).foregroundStyle(.secondary)
                if let error=detail.error {Text(error).foregroundStyle(.secondary)}
                DisclosureGroup("Check \(recap.sources.count) \(recap.sources.count == 1 ? "original":"originals")") {
                ForEach(Array(detail.sources.enumerated()),id:\.offset) {i,hit in
                    Button {m.openRecapSource(hit)} label: {
                        HStack {Text("[\(i+1)]").monospacedDigit();VStack(alignment:.leading,spacing:2) {Text(hit.title.isEmpty ? "Original source":hit.title).lineLimit(2);Text("\(hit.app) · \(hit.timestamp.formatted())").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"arrow.up.right")}.padding(8)
                    }.buttonStyle(.plain)
                }
                }
            } else {
                Label("Independent recap",systemImage:"doc.text").font(.headline)
                Text("This copy was saved without source links. Erasing an original does not remove it; delete this memory when needed.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
        .task(id:memory.evidenceHash) {
            guard memory.recap != nil else {return}
            detail.watch(memory,store:m.store) {if m.selected?.id==memory.id,m.selected?.evidenceHash==memory.evidenceHash {m.selected=nil;m.deletionStatus="A linked recap changed or its original was removed.";m.refresh();m.refreshChats()}}
        }
        .onDisappear {detail.stop()}
    }
}
