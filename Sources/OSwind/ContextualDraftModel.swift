import AppKit
import Combine
import OSwindCore

@MainActor final class ContextualDraftModel:ObservableObject {
    @Published var text="" {didSet {status=nil}}
    @Published var showing=false
    @Published private(set) var destination:DraftDestination?
    @Published private(set) var destinationStatus="Focus an editable field in another app, then press ⇧⌘Space to choose where this draft goes."
    @Published private(set) var busy=false
    @Published private(set) var status:String?
    @Published private(set) var error:String?
    @Published private(set) var sourceCount=0
    @Published private(set) var provider=""
    private let transport:any DraftInsertionTransport
    private let settle:() async throws ->Void
    private let copyText:(String) throws ->Void
    private var validateSources:(() async throws ->Void)?
    private var generation=UUID()
    private var work:Task<Void,Never>?
    init(transport:(any DraftInsertionTransport)?=nil,
         settle:@escaping () async throws ->Void={try await Task.sleep(for:.milliseconds(300))},
         copy:@escaping (String) throws ->Void={NSPasteboard.general.clearContents();guard NSPasteboard.general.setString($0,forType:.string) else {throw OSwindError.unavailable("The clipboard did not accept the draft.")}}) {
        self.transport=transport ?? NativeDraftInsertion();self.settle=settle;self.copyText=copy
    }
    var textError:String? {do {try DraftInsertionGuard.validateText(text);return nil}catch {return error.localizedDescription}}
    func chooseDestination(privacy:PrivacyPolicy) {
        // A new shortcut revokes any in-flight handoff before capturing focus.
        generation=UUID();work?.cancel();busy=false;destination=nil;transport.clear();error=nil;status=nil
        do {destination=try transport.capture(privacy:privacy);destinationStatus="Destination chosen with ⇧⌘Space. It expires after five minutes."}
        catch {destinationStatus=error.localizedDescription}
    }
    func review(_ answer:Answer,validate:@escaping () async throws ->Void) {
        guard !busy else {return}
        do {try DraftInsertionGuard.validateText(answer.text)}catch {self.error=error.localizedDescription;return}
        generation=UUID();work?.cancel();error=nil;text=answer.text;sourceCount=answer.sources.count;provider=answer.provider;validateSources=validate;showing=true
    }
    func insert(privacy:PrivacyPolicy) {
        guard !busy,let target=destination else {return}
        begin { [self] value in
            // Consume the destination before activation: any uncertain result
            // requires an explicit fresh shortcut rather than a duplicate retry.
            destination=nil
            destinationStatus="Choose a fresh destination with ⇧⌘Space for another insertion."
            defer {if generation==value.generation {transport.clear()}}
            try transport.activate(target)
            try await settle();try Task.checkCancellation()
            guard generation==value.generation else {throw CancellationError()}
            try transport.insert(value.text,at:target,privacy:privacy)
            status="The app acknowledged insertion. Review the destination before sending or saving."
            destinationStatus="Choose a fresh destination with ⇧⌘Space for another insertion."
        }
    }
    func copy() {
        begin { [self] value in try copyText(value.text);status="Copied the reviewed draft." }
    }
    private struct Work {let text:String,generation:UUID}
    private func begin(_ operation:@escaping (Work) async throws ->Void) {
        guard !busy,let validate=validateSources else {return}
        do {try DraftInsertionGuard.validateText(text)}catch {self.error=error.localizedDescription;return}
        let value=Work(text:text,generation:generation);busy=true;error=nil;status=nil
        work=Task { [weak self] in
            guard let self else {return}
            defer {if generation==value.generation {busy=false;work=nil}}
            do {
                try await validate();try Task.checkCancellation()
                guard generation==value.generation,text==value.text else {throw CancellationError()}
                try await operation(value)
            }catch is CancellationError {if generation==value.generation {error="Draft handoff cancelled."}}
            catch {if generation==value.generation {self.error=error.localizedDescription}}
        }
    }
    func cancelHandoff() {
        guard busy else {return}
        generation=UUID();work?.cancel();work=nil;busy=false;destination=nil;transport.clear();error=nil
        destinationStatus="Choose a fresh destination with ⇧⌘Space for another insertion."
        status="Pending handoff cancelled. Check the destination before trying again."
    }
    func clear() {
        generation=UUID();work?.cancel();work=nil;busy=false;showing=false;text="";destination=nil;transport.clear();validateSources=nil;sourceCount=0;provider="";error=nil;status=nil
        destinationStatus="Focus an editable field in another app, then press ⇧⌘Space to choose where this draft goes."
    }
    deinit {work?.cancel()}
}
