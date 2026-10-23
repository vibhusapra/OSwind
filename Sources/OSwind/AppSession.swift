import SwiftUI
import AppKit
import OSwindCore

@MainActor final class AppSession: ObservableObject {
    @Published var model: AppModel?
    @Published var failure: String?
    @Published var requested: URL
    let recoveryTransfer = LibraryTransferModel()
    private var selection: LibraryLocationSelection
    init(selection: LibraryLocationSelection? = nil) {
        let resolved = selection ?? LibraryLocationPreferences.selection(demo:CommandLine.arguments.contains("--demo"))
        self.selection = resolved; requested = resolved.url; load(resolved)
    }
    func retry() { load(selection) }
    func open(_ url: URL) {
        guard model?.libraryTransfer.busy != true, !recoveryTransfer.busy else { failure = "Complete or cancel the current transfer before changing libraries."; return }
        let selected = LibraryLocationSelection(url:url,requiresExisting:true,origin:"selected")
        do { try selected.validate(); let candidate = try AppModel(root:url,startServices:false); try LibraryLocationPreferences.save(url); model?.prepareForLibrarySwitch(); selection = selected; requested = url; model = candidate; failure = nil }
        catch { failure = error.localizedDescription }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Open library"
        guard panel.runModal() == .OK,let url = panel.url else { return }; open(url)
    }
    func openDefault() {
        let fallback = LibraryLocationSelection(url:Paths.data,requiresExisting:false,origin:"default")
        do { try fallback.validate(); let candidate = try AppModel(root:fallback.url,startServices:false); UserDefaults.standard.removeObject(forKey:LibraryLocationPreferences.key); model?.prepareForLibrarySwitch(); selection = fallback; requested = fallback.url; model = candidate; failure = nil }
        catch { failure = error.localizedDescription }
    }
    private func load(_ selected: LibraryLocationSelection) {
        do { try selected.validate(); model = try AppModel(root:selected.url); failure = nil }
        catch { model = nil; failure = error.localizedDescription }
    }
}
struct LibraryRecoveryView: View {
    @ObservedObject var session: AppSession
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Image(systemName:"externaldrive.badge.exclamationmark").font(.system(size:42)).foregroundStyle(OSwindTheme.accent)
                Text("Your library is unavailable.").font(.largeTitle.weight(.semibold))
                Text(session.failure ?? "Reconnect its drive or choose another library.").foregroundStyle(.secondary).textSelection(.enabled)
                Text(session.requested.path).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack { Button("Try again") { session.retry() }; Button("Choose library…") { session.choose() }; Button("Open default library") { session.openDefault() } }.disabled(session.recoveryTransfer.busy)
                Divider()
                Text("Restore from a backup").font(.title2.weight(.medium))
                LibraryTransferView(transfer:session.recoveryTransfer,store:nil)
            }.padding(40).frame(maxWidth:800,alignment:.leading).frame(maxWidth:.infinity)
        }
    }
}
