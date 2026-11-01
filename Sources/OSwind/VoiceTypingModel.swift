import Foundation
import Combine
import OSwindCore

@MainActor struct VoiceTypingEnvironment {
    var recorder:any DictationRecording
    var prepare:(AppSettings) async throws ->Void
    var transcribe:([Float],AppSettings) async throws ->SpeechTranscript
    var context:() async ->WindowContext? = {await AccessibilityContext.readPrivacyContext()}
    var identity:(WindowContext)->Bool = {AccessibilityContext.identityCurrent($0,targetBundleID:nil)}
    var locked:()->Bool = {SessionState.locked}
    var now:()->TimeInterval = {ProcessInfo.processInfo.systemUptime}
    var sleep:() async throws ->Void = {try await Task.sleep(for:.milliseconds(500))}
    static func live(store:MemoryStore,recognizer:SpeechRecognizer)->Self {
        .init(recorder:LocalDictationRecorder(),prepare:{settings in
            if settings.speech.engine == .parakeet {_ = try settings.speech.validateLocalModel()}
            else {guard FileManager.default.isExecutableFile(atPath:settings.whisperBinary),FileManager.default.fileExists(atPath:settings.whisperModel) else {throw OSwindError.unavailable("Choose a local speech model in Settings → Audio before recording.")}}
            try await recognizer.prepare(settings:settings)
        },transcribe:{samples,settings in try await LocalDictation.transcribe(samples:samples,store:store,settings:settings,recognizer:recognizer)})
    }
}

/// One worker owns preparation, permission, recording, and transcription. Cancel
/// revokes admission immediately; busy clears only after actual work has joined.
@MainActor final class VoiceTypingModel:ObservableObject {
    @Published private(set) var busy=false
    @Published private(set) var recording=false
    @Published private(set) var status="Record up to 30 seconds, then review your words."
    @Published private(set) var elapsed=0
    private let store:MemoryStore,draft:ContextualDraftModel,environment:VoiceTypingEnvironment
    private var settings:AppSettings,generation=UUID(),worker:Task<Void,Never>?
    private var pending:[Float]?
    var allowed:()->Bool = {false}
    init(store:MemoryStore,settings:AppSettings,draft:ContextualDraftModel,environment:VoiceTypingEnvironment) {
        self.store=store;self.settings=settings;self.draft=draft;self.environment=environment
    }
    func apply(_ value:AppSettings) {
        let changed=settings.privacy != value.privacy || settings.speech != value.speech || settings.whisperBinary != value.whisperBinary || settings.whisperModel != value.whisperModel || settings.transcriptionLanguage != value.transcriptionLanguage
        settings=value
        if changed {cancel(clearDraft:true)}
    }
    private func current(_ token:UUID,_ config:AppSettings) throws {
        try Task.checkCancellation()
        guard generation==token,allowed(),!store.isClosed,!environment.locked(),settings.privacy==config.privacy,settings.speech==config.speech,settings.whisperBinary==config.whisperBinary,settings.whisperModel==config.whisperModel,settings.transcriptionLanguage==config.transcriptionLanguage else {throw CancellationError()}
        try store.validateDirectoryIdentity()
    }
    private func validate(_ token:UUID,_ config:AppSettings) async throws {
        try current(token,config)
        guard let context=await environment.context() else {throw OSwindError.unavailable("Current application privacy context is unavailable.")}
        try current(token,config)
        guard environment.identity(context),!context.secure,config.privacy.exclusion(app:context.bundle,title:context.title,url:context.url,isBrowser:context.browser)==nil else {throw OSwindError.unavailable("Voice typing paused for private or changed application context.")}
    }
    func start() {
        guard !busy,!draft.busy else {return}
        guard allowed(),!store.isClosed,!environment.locked() else {status="Finish other microphone work and unlock this library before recording.";return}
        let token=UUID(),config=settings,revision=draft.revision;generation=token
        busy=true;elapsed=0;pending=nil;status="Preparing local speech…"
        worker=Task {[weak self] in
            guard let self else {return}
            defer {environment.recorder.cancel();pending=nil;recording=false;busy=false;worker=nil;if status.hasPrefix("Cancelling") {status="Dictation cancelled."}}
            do {
                try await validate(token,config)
                try await environment.prepare(config)
                try await validate(token,config)
                try await environment.recorder.start()
                try await validate(token,config)
                guard draft.revision==revision else {throw CancellationError()}
                recording=true;status="Listening · stop when you’re ready"
                let began=environment.now()
                while recording {
                    try await environment.sleep()
                    try await validate(token,config)
                    guard draft.revision==revision else {throw CancellationError()}
                    let delta=environment.now()-began
                    guard delta.isFinite,delta>=0 else {throw CancellationError()}
                    let seconds=min(LocalDictation.maximumSeconds,Int(min(delta,30)));if elapsed != seconds {elapsed=seconds}
                    if environment.recorder.readyToFinish || delta>=Double(LocalDictation.maximumSeconds) {finishRecording()}
                }
                try current(token,config)
                guard let samples=pending else {throw CancellationError()};pending=nil
                status="Transcribing on this Mac…"
                let transcript=try await environment.transcribe(samples,config)
                try await validate(token,config)
                guard draft.revision==revision,!draft.busy else {throw CancellationError()}
                try DraftInsertionGuard.validateText(transcript.text)
                draft.revokeDestination()
                draft.review(Answer(text:transcript.text,sources:[],provider:"Local dictation",duration:0)) {[weak self] in
                    guard let self else {throw CancellationError()}
                    try await self.validate(token,config)
                }
                status="Review and edit your words before inserting or copying."
            }catch is CancellationError {if generation==token {status="Dictation cancelled."}}
            catch {if generation==token {status=error.localizedDescription}}
        }
    }
    func finishRecording() {
        guard recording else {return}
        recording=false
        do {pending=try environment.recorder.finish();status="Finishing recording…"}
        catch {status=error.localizedDescription;generation=UUID();worker?.cancel();pending=nil}
    }
    func cancel(clearDraft:Bool=false) {
        guard busy || clearDraft else {return}
        generation=UUID();worker?.cancel();environment.recorder.cancel();recording=false;pending=nil
        status=busy ? "Cancelling · waiting for local work…":"Record up to 30 seconds, then review your words."
        if clearDraft {draft.clear()}
    }
    func cancelAndWait() async {cancel(clearDraft:true);let task=worker;await task?.value}
    #if DEBUG
    static func preview(store:MemoryStore,draft:ContextualDraftModel,stage:String)->VoiceTypingModel {
        var env=VoiceTypingEnvironment(recorder:VoicePreviewRecorder(),prepare:{_ in throw CancellationError()},transcribe:{_,_ in throw CancellationError()})
        env.context={nil};env.identity={_ in false};env.locked={true}
        let model=VoiceTypingModel(store:store,settings:AppSettings(),draft:draft,environment:env)
        if stage=="VoiceListening" {model.recording=true;model.busy=true;model.elapsed=12;model.status="Listening · stop when you’re ready"}
        if stage=="VoiceTranscribing" {model.busy=true;model.status="Transcribing on this Mac…"}
        if stage=="VoiceReview" {
            draft.review(Answer(text:"Let’s keep the rollout small. Mira owns the release checklist, and I’ll verify the remaining device checks before Friday.",sources:[],provider:"Local dictation · sample",duration:0),validate:{throw CancellationError()})
            model.status="Review and edit your words before inserting or copying."
        }
        return model
    }
    #endif
    deinit {worker?.cancel()}
}
