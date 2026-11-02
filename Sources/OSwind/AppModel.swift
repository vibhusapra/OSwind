import SwiftUI
import Combine
import OSwindCore
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import EventKit

@MainActor final class AppModel: ObservableObject {
    let store: MemoryStore
    let drafting:ContextualDraftModel
    let embedder = LocalEmbedder()
    let capture: CaptureController
    let audio: AudioController
    let entityMemory:EntityMemoryModel
    @Published var entityScope:MemoryEntity?
    let meetings:MeetingsModel
    let tools:MCPToolsModel
    let clipboard:ClipboardContextModel
    let voice:VoiceTypingModel
    let workflow:WorkflowModel
    private var libraryRetired=false
    private var resumeMeetingsAfterPause=false,resumeScreenWithMeetings=false,resumeOnlyClipboard=false
    let activity:ActivityCalendarModel
    @Published var calendarSlice:DateInterval?
    @Published var calendarSliceZone:String?
    let libraryTransfer = LibraryTransferModel()
    let libraryWipe=LibraryWipeModel()
    lazy var pendingMediaCleanup=PendingMediaCleanupModel(store:store,onFinished:{[weak self] in self?.invalidateStorageEstimate()},onWipeState:{[weak self] pending in self?.libraryWipe.pendingCleanup=pending})
    let libraryWork=LibraryWorkRegistry()
    var libraryStatusAvailable:Bool {!libraryRetired && !store.isClosed}
    var libraryWorkAvailable:Bool {libraryStatusAvailable && destructiveDrainers==0 && libraryWork.accepting}
    let routines:RoutinesModel
    let nativeModels:NativeModelSetupModel
    let visualModelSetup:VisualModelSetupModel
    let piiModelSetup:PIIModelSetupModel
    @Published var settingsTab = "Capture"
    private var assigningSettingsInternally=false
    @Published var settings: AppSettings { didSet {
        // A delayed binding can arrive after its view's workspace departed.
        // Restore the local value before touching controllers or preferences.
        guard !assigningSettingsInternally else {return}
        guard !libraryRetired,!store.isClosed else {
            assignInternalSettings(oldValue);return
        }
        applySettingsToControllers()
        if oldValue.privacy != settings.privacy {drafting.clear();cancelJSONImport();libraryWork.cancel(kinds:[.note,.recap]);cancelMaintenanceWork();cancelAnswer()}
        if oldValue.automaticMaintenance && !settings.automaticMaintenance {cancelMaintenanceWork(automaticOnly:true)}
        if oldValue.search.indexOnLowPower != settings.search.indexOnLowPower {cancelMaintenanceWork()}
        if oldValue.piiImports != settings.piiImports {cancelJSONImport()}
        if oldValue.ai != settings.ai {cancelAnswer()}
        if oldValue.privacy != settings.privacy || oldValue.retainAudio != settings.retainAudio || oldValue.speech != settings.speech || oldValue.diarization != settings.diarization || oldValue.whisperBinary != settings.whisperBinary || oldValue.whisperModel != settings.whisperModel || oldValue.transcriptionLanguage != settings.transcriptionLanguage {cancelAudioImport()}
        if oldValue.search.visual != settings.search.visual || oldValue.privacy != settings.privacy || oldValue.search.indexOnLowPower != settings.search.indexOnLowPower {cancelVisualIndexing();if mode == .visual {cancelOpeningMemory();hits=[];selected=nil;selectedVisual=nil;refresh()}}
        // Visual model controls do not invalidate the independent text index.
        var oldTextSearch=oldValue.search;oldTextSearch.visual=settings.search.visual
        if oldTextSearch != settings.search { indexGeneration = UUID(); indexTask?.cancel(); store.cancelSearchIndexBuild(); if settings.search.indexPolicy == .exact { store.releaseSearchIndex() }; cancelAutomaticIndexer(); libraryWork.cancel(kinds:[.textRebuild,.fastIndex]);indexing = libraryWork.count(kinds:[.textRebuild,.fastIndex])>0; indexStatus = indexing ? "Stopping previous search work…":"Search settings changed; prepare the selected index" }
        do { try settings.save(root:store.root) } catch { errorMessage = error.localizedDescription }
    } }
    private func assignInternalSettings(_ value:AppSettings) {
        assigningSettingsInternally=true;settings=value;assigningSettingsInternally=false
    }
    private func applySettingsToControllers() {
        capture.settings=settings;audio.settings=settings;routines.apply(settings);meetings.apply(settings);tools.apply(settings);clipboard.apply(settings);voice.apply(settings);workflow.apply(settings)
    }
    @Published var section = "Memories" {didSet {if section != "Memories" && section != "Ask" {entityScope=nil}}}
    @Published var searchFocusRequest: UUID?
    @Published var query = ""
    @Published var mode: SearchMode = .hybrid
    @Published var visualIndexing=false
    @Published var visualAutomaticIndexing=false
    var visualAutoResumeAllowed=false
    @Published var visualIndexProgress=0.0
    @Published var visualIndexStatus="Enable a local visual model to index retained screenshots and replay frames."
    var visualGeneration=UUID()
    var visualIndexTask:Task<Void,Never>?
    var visualAutomaticTask:Task<Void,Never>?
    var pendingVisualIDs=[String]()
    @Published var appFilter = "All apps"
    @Published var range = "All time"
    @Published var date = Date()
    @Published var hits = [SearchHit]()
    @Published var stats = StoreStats()
    @Published var storageUpdatedAt: Date?
    @Published var selected: Memory? {didSet {if selected==nil {selectedVisual=nil};refreshSelectedPIIScan();watchSelectedOriginal()}}
    @Published var selectedPIIScan:PIIScanStatus?
    @Published var selectedPIIScanError:String?
    private var piiScanStatusGeneration=UUID()
    @Published private(set) var openingMemoryID:String?
    private var historicalDetailTask:Task<Void,Never>?
    private var historicalDetailGeneration=UUID()
    private var detailGeneration=UUID()
    @Published var selectedEvidenceQuery = ""
    @Published var answer: Answer?
    @Published var question = ""
    @Published var asking = false
    @Published var chats = [ChatSession]()
    @Published var chatTurns = [ChatTurn]()
    @Published var currentChatID: String?
    @Published var answerStatus:String?
    @Published private(set) var savedAnswerID:String?
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showOnboarding = false {didSet {
        if showOnboarding {suspendConfiguredServices()}
        else if oldValue {activateConfiguredServices();if housekeepingRequested && !housekeepingActive {startHousekeeping()}}
    }}
    @Published var pauseUntil: Date?
    private var pauseTimer: Timer?
    @Published var apiStatus = "API off"
    @Published var searchMS = 0.0
    @Published var searchStrategy = ""
    @Published var refreshing = false
    @Published private(set) var deletingID:String?
    @Published var deletionStatus:String?
    @Published private(set) var savingRecap=false
    @Published var recapSaveStatus:String?
    @Published private(set) var importingJSON=false
    @Published private(set) var importStatus=""
    private var jsonImportTask:Task<Void,Never>?
    private var jsonImportWorker:Task<String,Error>?
    private var jsonImportDrainers=0
    var hasPendingJSONImport:Bool {jsonImportWorker != nil || jsonImportTask != nil}
    private var deletionTask:Task<Void,Never>?
    private var deletionWorker:Task<HistoryErasureResult,Error>?
    private var maintenanceTask:Task<Void,Never>?
    private var maintenanceWorker:Task<(RetentionCleanupResult?,String?),Error>?
    private var maintenanceAutomatic=false
    private var destructiveDrainers=0
    var hasPendingDestructiveWork:Bool {deletionTask != nil || deletionWorker != nil || maintenanceTask != nil || maintenanceWorker != nil}
    var hasPendingExitWork:Bool {hasPendingJSONImport || hasPendingDestructiveWork || libraryWork.busy || pendingMediaCleanup.hasPendingWork || tools.busy || clipboard.busy || voice.busy || workflow.busy}
    private var libraryOperationGeneration=UUID()
    @Published private(set) var maintenanceBusy=false
    @Published private(set) var maintenanceStatus=""
    @Published var searchWarnings = [String]()
    @Published var interpretQuery = true
    @Published var resolvedSearch: QueryResolution?
    @Published var searchInputError: String?
    @Published var answerInputError: String?
    @Published var installedModels = [InstalledModel]()
    @Published var localRuntime = ""
    @Published var startingModelServer = false
    @Published var modelStatus = "Check the local server to discover installed models"
    @Published var pullProgress: ModelPullProgress?
    @Published var pullingModel: String?
    enum SearchWorkPhase:Hashable,Sendable {case query,queryRead,textRebuild,fastIndex,automaticText,visualRebuild,automaticVisual}
    var searchWorkObserver:(@Sendable (SearchWorkPhase)async throws->Void)?
    var searchWorkCompleted:(@Sendable (SearchWorkPhase)->Void)?
    @Published var indexing = false
    @Published var indexStatus = "Apple vectors are indexed during capture"
    @Published var indexProgress = 0.0
    private var searchGeneration=UUID(),automaticIndexGeneration=UUID()
    private var indexGeneration = UUID()
    private var indexTask: Task<Void,Never>?
    private var pullTask: Task<Void,Never>?
    private var automaticIndexTask: Task<Void,Never>?
    private var pendingIndex = [Memory]()
    private var pendingRefresh = false
    let demo: Bool
    private var api: LocalAPIServer?
    private var apiGeneration=UUID()
    private var configuredServicesRequested=false
    private(set) var configuredServicesActive=false
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void,Never>?
    private var statisticsTask:UUID?
    private var diskUsageTask:UUID?
    private var statisticsUpdatedAt = Date.distantPast
    private var statisticsPending = false
    private var storageGeneration = UUID()
    @Published var importingAudio=false
    @Published var audioImportStatus=""
    private var housekeeping: Timer?
    private var housekeepingRequested=false
    @Published private(set) var housekeepingActive=false
    init(root selectedRoot: URL? = nil, startServices: Bool = true, nativeModelSetup:NativeModelSetupModel?=nil,visualSetup:VisualModelSetupModel?=nil,piiSetup:PIIModelSetupModel?=nil,preparedStore:MemoryStore?=nil,drafting:ContextualDraftModel?=nil,meetingsSetup:((MemoryStore,AppSettings)->MeetingsModel)?=nil,toolsSetup:((MemoryStore,AppSettings)->MCPToolsModel)?=nil,clipboardSetup:((MemoryStore,AppSettings)->ClipboardContextModel)?=nil,voiceSetup:((MemoryStore,AppSettings,ContextualDraftModel)->VoiceTypingModel)?=nil,workflowSetup:((MemoryStore,AppSettings)->WorkflowModel)?=nil) throws {
        self.drafting=drafting ?? ContextualDraftModel()
        nativeModels=nativeModelSetup ?? NativeModelSetupModel()
        visualModelSetup=visualSetup ?? VisualModelSetupModel()
        piiModelSetup=piiSetup ?? PIIModelSetupModel()
        demo = CommandLine.arguments.contains("--demo")
        let resolved = LibraryLocationPreferences.selection(demo:demo)
        let root = selectedRoot ?? resolved.url
        if selectedRoot == nil { try resolved.validate() }
        if let preparedStore {
            guard !preparedStore.isClosed,preparedStore.root.standardizedFileURL==root.standardizedFileURL else {throw OSwindError.invalid("Prepared library does not match the selected location")}
            try preparedStore.validateDirectoryIdentity()
            store=preparedStore
        }else {store = try MemoryStore(root:root)}
        let loaded = AppSettings.load(root:root)
        settings = loaded
        capture = CaptureController(store:store, embedder:embedder, settings:loaded)
        audio = AudioController(store:store, embedder:embedder, settings:loaded)
        entityMemory=EntityMemoryModel(store:store)
        activity=ActivityCalendarModel(store:store)
        meetings=meetingsSetup?(store,loaded) ?? MeetingsModel(store:store,settings:loaded)
        routines=RoutinesModel(store:store,embedder:embedder,settings:loaded)
        tools=toolsSetup?(store,loaded) ?? MCPToolsModel(store:store,settings:loaded)
        clipboard=clipboardSetup?(store,loaded) ?? ClipboardContextModel(store:store,settings:loaded)
        voice=voiceSetup?(store,loaded,self.drafting) ?? VoiceTypingModel(store:store,settings:loaded,draft:self.drafting,environment:.live(store:store,recognizer:audio.recognizer))
        workflow=workflowSetup?(store,loaded) ?? WorkflowModel(store:store,settings:loaded,environment:.live(store:store))
        workflow.allowed = {[weak self] in
            guard let self else {return false}
            return !self.demo && !self.libraryRetired && !self.showOnboarding && !self.libraryWipe.busy && !self.libraryWipe.pendingCleanup && !self.libraryTransfer.busy && !self.maintenanceBusy && self.deletingID==nil
        }
        workflow.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&cancellables)
        voice.allowed = {[weak self] in
            guard let self else {return false}
            return !self.demo && !self.libraryRetired && !self.showOnboarding && !self.libraryWipe.busy && !self.libraryWipe.pendingCleanup && !self.libraryTransfer.busy && !self.maintenanceBusy && !self.audio.hasActiveWork && !self.importingAudio
        }
        voice.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&cancellables)
        meetings.allowed = {[weak self] in
            guard let self else {return false}
            return !self.demo && !self.libraryRetired && !self.showOnboarding && !self.libraryWipe.busy && !self.libraryWipe.pendingCleanup && !self.libraryTransfer.busy && !self.maintenanceBusy
        }
        meetings.savePreferences = {[weak self] configuration in
            guard let self,!self.store.isClosed,!self.libraryRetired else {throw OSwindError.unavailable("The calendar library is closed.")}
            try self.store.validateDirectoryIdentity()
            var next=self.settings;next.meetings=configuration;try next.save(root:self.store.root);self.settings=next
        }
        meetings.prepareBrief = {[weak self] event in self?.prepareMeetingBrief(event)}
        tools.allowed = {[weak self] in
            guard let self else {return false}
            return !self.demo && !self.libraryRetired && !self.showOnboarding && !self.libraryWipe.busy && !self.libraryWipe.pendingCleanup && !self.libraryTransfer.busy && !self.maintenanceBusy && !self.importingJSON
        }
        tools.saveProfiles = {[weak self] profiles in
            guard let self,!self.store.isClosed,!self.libraryRetired else {throw OSwindError.unavailable("The tools library is closed")}
            try MCPConnectionProfile.validate(profiles);try self.store.validateDirectoryIdentity()
            var next=self.settings;next.mcpConnections=profiles;try next.save(root:self.store.root);self.settings=next
        }
        tools.saveSource = {[weak self] draft in
            guard let self else {throw OSwindError.unavailable("The tools library is unavailable")}
            return try await self.saveMCPResult(draft)
        }
        clipboard.allowed = {[weak self] in
            guard let self else {return false}
            return !self.demo && !self.libraryRetired && !self.showOnboarding && !self.libraryWipe.busy && !self.libraryWipe.pendingCleanup && !self.libraryTransfer.busy && !self.maintenanceBusy && !self.importingJSON
        }
        clipboard.saveSource = {[weak self] draft in
            guard let self else {throw OSwindError.unavailable("The clipboard library is unavailable")}
            return try await self.saveClipboardResult(draft)
        }
        clipboard.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&cancellables)
        tools.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&cancellables)
        meetings.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&cancellables)
        routines.onChange = {[weak self] in self?.refreshChats()}
        libraryWipe.pendingCleanup=(try? store.hasPendingLibraryWipeCleanup()) ?? false
        visualModelSetup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        entityMemory.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        libraryWipe.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        capture.onCapture = { [weak self] memory in self?.captured(memory) }; audio.onCapture = { [weak self] memory in self?.captured(memory) }
        capture.onObservation = {[weak self] memory in self?.observed(memory)}
        self.drafting.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for:name).sink { [weak self] _ in self?.audio.stop();self?.voice.cancel(clearDraft:true);self?.workflow.cancel(clear:true);self?.drafting.clear();self?.meetings.sleep();self?.tools.suspend() }.store(in:&cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didWakeNotification).sink { [weak self] _ in self?.resumeConfiguredWorkAfterWake() }.store(in:&cancellables)
        NotificationCenter.default.publisher(for:.EKEventStoreChanged).sink {[weak self] _ in Task {@MainActor in self?.meetings.invalidate()}}.store(in:&cancellables)
        for name in [NSWorkspace.screensDidWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for:name).sink {[weak self] _ in Task {@MainActor in self?.meetings.wake()}}.store(in:&cancellables)
        }
        if demo { try? seedDemo() }
        showOnboarding = !demo && !UserDefaults.standard.bool(forKey:"onboarded")
        refresh(forceStatistics:true); refreshChats(); if startServices { startConfiguredServices() }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.publisher(for:name).sink { [weak self] _ in Task {@MainActor in self?.resumeAutomaticVisualIndex();self?.meetings.configureTimer()} }.store(in:&cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.sessionDidBecomeActiveNotification).sink { [weak self] _ in Task {@MainActor in self?.resumeAutomaticVisualIndex()} }.store(in:&cancellables)
    }
    private func stopHousekeeping(cancelWork:Bool=true) {housekeeping?.invalidate();housekeeping=nil;housekeepingActive=false;if cancelWork {cancelMaintenanceWork(automaticOnly:true)}}
    private func startHousekeeping() {
        stopHousekeeping(cancelWork:false)
        guard !libraryRetired,!store.isClosed,housekeepingRequested,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup else {cancelMaintenanceWork(automaticOnly:true);return}
        housekeeping=Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in Task { @MainActor in self?.maintain(automatic:true) } }
        housekeepingActive=true
    }
    func configureAutomaticMaintenance(_ enabled:Bool) {
        guard !libraryRetired,!store.isClosed else {return}
        settings.automaticMaintenance=enabled
        if enabled {housekeepingRequested=true;startHousekeeping()}
    }
    func startConfiguredServices() {
        guard !libraryRetired,!store.isClosed,destructiveDrainers==0 else {return}
        configuredServicesRequested=true;housekeepingRequested=true
        activateConfiguredServices()
    }
    private func activateConfiguredServices() {
        guard !libraryRetired,destructiveDrainers==0,configuredServicesRequested,!configuredServicesActive,!showOnboarding,!store.isClosed,!libraryWipe.busy,!libraryWipe.pendingCleanup else {return}
        configuredServicesActive=true;visualAutoResumeAllowed=true;startHousekeeping();pendingMediaCleanup.start()
        if !demo && settings.routinesEnabled {routines.start()}
        if !demo && settings.meetings.enabled {meetings.start()}
        if !demo && settings.clipboard.enabled {clipboard.start()}
        if settings.apiEnabled {startAPI()}
        if settings.captureOnLaunch && !demo {capture.start()}
        if settings.entityAutomaticIndex && !demo {entityMemory.build()}
        resumeAutomaticVisualIndex()
    }
    private func suspendConfiguredServices() {
        configuredServicesActive=false;stopHousekeeping();pendingMediaCleanup.stop();drafting.clear()
        visualAutoResumeAllowed=false;cancelVisualIndexing();entityMemory.cancel();routines.stop()
        pauseAll(discardReplay:true,manualMeetingPause:false);stopAPI(preservePreference:true)
    }
    private func resumeConfiguredWorkAfterWake() {
        guard !libraryRetired,destructiveDrainers==0,!showOnboarding,!demo,!store.isClosed,!libraryWipe.busy,!libraryWipe.pendingCleanup else {return}
        pendingMediaCleanup.resume()
        routines.tickIfStarted();meetings.wake()
        if configuredServicesActive && settings.entityAutomaticIndex {entityMemory.build()}
        resumeAutomaticVisualIndex()
    }
    func configureClipboard(_ enabled:Bool) {
        guard !store.isClosed,!libraryRetired,!libraryWipe.busy,!libraryWipe.pendingCleanup else {return}
        settings.clipboard.enabled=enabled
        if enabled,!showOnboarding {clipboard.start()}else {clipboard.stop()}
    }
    func configureRoutineScheduling(_ enabled:Bool) {
        settings.routinesEnabled=enabled
        guard enabled,!showOnboarding,!demo,!store.isClosed,!libraryWipe.busy,!libraryWipe.pendingCleanup else {routines.stop();return}
        // Explicit schedule controls authorize this service only, including a
        // quietly prepared library. They do not start capture or the API.
        routines.start()
    }
    func selectPreparedVisualModel(_ installed:VisualModelInstallation) {
        guard !store.isClosed else {return}
        settings.search.visual.modelDirectory=installed.directory.path
        visualIndexStatus=settings.search.visual.enabled ? "Local visual models are ready. Build / resume to search existing history.":"Local visual models are ready. Enable visual memory, then build / resume its index."
    }
    func prepareForLibrarySwitch() {
        resumeMeetingsAfterPause=false;resumeScreenWithMeetings=false
        libraryRetired=true;answerStatus=nil;savedAnswerID=nil;pendingMediaCleanup.stop();meetings.stop(clear:true);tools.suspend();clipboard.stop();voice.cancel(clearDraft:true);workflow.cancel(clear:true)
        configuredServicesRequested=false;configuredServicesActive=false
        housekeepingRequested=false;stopHousekeeping()
        drafting.clear()
        entityMemory.clear();entityScope=nil
        activity.deactivate(clear:true)
        visualAutoResumeAllowed=false;cancelVisualIndexing();visualModelSetup.cancel();piiModelSetup.cancel()
        libraryOperationGeneration=UUID();cancelJSONImport();cancelDestructiveWork();libraryWork.cancel();libraryWipe.cancel()
        routines.stop();capture.pause(discardReplay:true); cancelOpeningMemory(); selected=nil; nativeModels.cancel(); pauseAll(); cancelAnswer(); cancelIndexing(); cancelAutomaticIndexer(); pullTask?.cancel(); cancelRefresh(); statisticsPending=false; stopAPI(preservePreference:true)
    }
    func clearForVaultLock() {
        prepareForLibrarySwitch();libraryTransfer.cancel();routines.clearForLock()
        calendarSlice=nil;calendarSliceZone=nil
        hits.removeAll();selected=nil;selectedVisual=nil;answer=nil;answerStatus=nil;chats.removeAll();chatTurns.removeAll();currentChatID=nil;query="";question="";resolvedSearch=nil;selectedEvidenceQuery="";errorMessage=nil
    }
    var filter: SearchFilter { filter(at:Date()) }
    func filter(at now: Date) -> SearchFilter {
        let calendar = Calendar.current; var start: Date?, end: Date?
        switch range {
        case "Today": let day = calendar.dateInterval(of:.day,for:now); start = day?.start; end = day?.end
        case "Yesterday": end = calendar.startOfDay(for:now); start = calendar.date(byAdding:.day,value:-1,to:end!)
        case "7 days": start = calendar.date(byAdding:.day,value:-7,to:now); end = now
        case "30 days": start = calendar.date(byAdding:.day,value:-30,to:now); end = now
        case "Calendar slice":
            start=calendarSlice?.start ?? .distantFuture;end=calendarSlice?.end ?? .distantPast
        case "Choose day": start = calendar.startOfDay(for:date); end = calendar.date(byAdding:.day,value:1,to:start!)
        default: break
        }
        return SearchFilter(query:query,app:appFilter == "All apps" ? nil : appFilter,kind:section == "Conversations" ? .audio : section == "Notes" ? .note : section == "Recaps" ? .summary : nil,start:start,end:end,favoritesOnly:section == "Saved",entityID:entityScope?.id,limit:200,sourceStartsOnly:range=="Calendar slice" ? true:nil)
    }
    func browseEntity(_ entity:MemoryEntity,ask:Bool) {
        cancelOpeningMemory();selected=nil;hits=[];resolvedSearch=nil;entityScope=entity;query="";appFilter="All apps";range="All time";section=ask ? "Ask":"Memories";refresh()
    }
    func browseActivity(start:Date,end:Date,snapshot:ActivityCalendarSnapshot) {
        guard !store.isClosed else {return}
        let lower=max(start,snapshot.scope.start ?? start),upper=min(end,snapshot.scope.end ?? end)
        guard lower<upper else {errorMessage="The selected calendar interval and source filters do not overlap";return}
        func quoted(_ value:String)->String {String(data:(try? JSONEncoder().encode(value)) ?? Data(),encoding:.utf8) ?? "\"\""}
        var terms=[String]()
        if let kind=snapshot.scope.kind {terms.append("kind:"+kind.rawValue)}
        if snapshot.scope.favoritesOnly {terms.append("is:favorite")}
        if let tag=snapshot.scope.tag {terms.append("tag:"+quoted(tag))}
        if let speaker=snapshot.scope.speaker {terms.append("speaker:"+quoted(speaker))}
        cancelOpeningMemory();selected=nil;hits=[];resolvedSearch=nil;searchInputError=nil
        calendarSlice=DateInterval(start:lower,end:upper);calendarSliceZone=snapshot.timeZone
        appFilter=snapshot.scope.app ?? "All apps";query=terms.joined(separator:" ");interpretQuery=true;mode = .keyword
        range="Calendar slice";section="Memories";refresh()
    }
    var activeSearchQuery: String { resolvedSearch?.originalQuery == query ? resolvedSearch!.filter.query : query }
    func focusSearch() {
        cancelOpeningMemory(); section = "Memories"; showSettings = false; selected = nil
        searchFocusRequest = UUID()
        // Returning from a non-search section can change the effective scope
        // without changing query text, so the cached hits must be refreshed.
        refresh()
    }
    @Published var selectedPassage: PassageRange?
    @Published var selectedVisual:VisualMatch?
    @discardableResult func refreshSelectedPIIScan(read:(@Sendable (Memory)throws->PIIScanStatus)?=nil) -> Task<Void,Never>? {
        libraryWork.cancel(kinds:[.selectedPII]);piiScanStatusGeneration=UUID()
        selectedPIIScan=nil;selectedPIIScanError=nil
        guard libraryWorkAvailable,let memory=selected,memory.originalEvidence==nil else {return nil}
        let store=self.store,generation=piiScanStatusGeneration,registry=libraryWork
        guard let id=registry.launch(kind:.selectedPII,operation:{
            try Task.checkCancellation()
            if let read {return try read(memory)}
            return try store.piiScanStatus(memory.id,matching:memory)
        },completion:{[weak self] outcome,cancelled in
            guard let self,!cancelled,self.libraryWorkAvailable,self.piiScanStatusGeneration==generation,self.selected?.id==memory.id else {return}
            switch outcome {
            case .success(let value):self.selectedPIIScan=value
            case .failure:self.selectedPIIScanError="The local import-check record is unavailable."
            }
        }) else {return nil}
        return Task {await registry.wait(for:id)}
    }
    /// Selection reads are revalidated while visible. Erasure or library shutdown
    /// closes historical text as well as historical recap cards; no current ID
    /// can replace the selected original. Media playback remains unavailable.
    func watchSelectedOriginal(interval:UInt64=2_000_000_000,read:(@Sendable (Memory)throws->Memory)?=nil) {
        historicalDetailTask?.cancel();historicalDetailTask=nil;libraryWork.cancel(kinds:[.historicalValidation]);historicalDetailGeneration=UUID()
        guard libraryWorkAvailable,let memory=selected,memory.originalEvidence != nil else {return}
        let store=self.store,generation=historicalDetailGeneration,registry=libraryWork
        historicalDetailTask=Task { [weak self] in
            while !Task.isCancelled {
                guard self?.historicalDetailGeneration==generation,self?.libraryWorkAvailable==true else {return}
                guard let id=registry.launch(kind:.historicalValidation,operation:{
                    try Task.checkCancellation()
                    let current=try read?(memory) ?? store.hydrate(memory)
                    try Task.checkCancellation()
                    guard current.originalEvidence==memory.originalEvidence,current.recap==memory.recap else {throw OSwindError.unavailable("Original evidence changed")}
                },completion:{[weak self] outcome,cancelled in
                    guard let self,!cancelled,self.libraryWorkAvailable,self.historicalDetailGeneration==generation else {return}
                    if case .failure(let error)=outcome,!(error is CancellationError) {self.selected=nil;self.deletionStatus="The selected original changed or was removed."}
                }) else {return}
                await registry.wait(for:id)
                guard !Task.isCancelled,self?.historicalDetailGeneration==generation else {return}
                do {try await Task.sleep(nanoseconds:interval)}catch {return}
            }
        }
    }
    func cancelOpeningMemory() {
        libraryWork.cancel(kinds:[.sourceOpening]);detailGeneration=UUID();openingMemoryID=nil
    }
    func openMemory(_ memory:Memory,query:String,passage:PassageRange?=nil,visual:VisualMatch?=nil,observeRead:(@Sendable ()throws->Void)?=nil) {
        let store=self.store
        openSource(id:memory.id,query:query,passage:passage,visual:visual) {try observeRead?();return try store.hydrate([SearchHit(memory:memory,score:0,match:"",passage:passage,visual:visual)],pinTextObservations:true)[0].memory}
    }
    func openWorkflowSource(_ source:WorkflowSourceBinding) {
        guard !libraryRetired,!store.isClosed else {return}
        let store=self.store
        openSource(id:source.memoryID,query:"",passage:nil,load:{
            guard let memory=try store.get(source.memoryID) else {throw OSwindError.unavailable("This workflow source is no longer available")}
            return memory
        })
    }
    func openMCPSource(_ id:String) {
        let store=self.store
        openSource(id:id,query:"",passage:nil) {guard let memory=try store.get(id) else {throw OSwindError.unavailable("The saved tool source no longer exists")};return memory}
    }
    func openEntitySource(_ source:EntitySource) {
        let store=self.store
        openSource(id:source.id,query:source.surface,passage:source.passage) {try store.entitySourceMemory(source)}
    }
    func openRecapSource(_ card:RecapSourceCard) {
        let store=self.store
        openSource(id:card.id,query:"",passage:card.passage) {
            try store.recapSourceMemory(card)
        }
    }
    private func openSource(id:String,query:String,passage:PassageRange?,visual:VisualMatch?=nil,load:@escaping @Sendable () throws -> Memory) {
        guard libraryWorkAvailable else {return}
        cancelOpeningMemory();let generation=detailGeneration
        openingMemoryID=id
        libraryWork.launch(kind:.sourceOpening,priority:.userInitiated,operation:{try Task.checkCancellation();return try load()}) {[weak self] outcome,cancelled in
            guard let self,!cancelled,self.libraryWorkAvailable,self.detailGeneration==generation else {return}
            self.openingMemoryID=nil
            switch outcome {
            case .success(let full):self.selectedEvidenceQuery=query;self.selectedPassage=passage;self.selectedVisual=visual;self.selected=full
            case .failure(let error):self.errorMessage=error.localizedDescription
            }
        }
    }
    private func cancelRefresh() {
        searchGeneration=UUID();refreshTask?.cancel();refreshTask=nil;libraryWork.cancel(kinds:[.query]);refreshing=false;pendingRefresh=false
    }
    func refresh(forceStatistics:Bool=false) {
        guard libraryWorkAvailable else {return}
        refreshStatistics(force:forceStatistics);cancelRefresh()
        if section=="People & projects" {entityMemory.reload();return}
        if section=="Calendar" {activity.resumeAndInvalidate();return}
        if section=="Meetings" || section=="Tools" {return}
        searchInputError=nil
        let now=Date(),mode=self.mode,filter=self.filter(at:now),interpret=interpretQuery,configuration=settings.search,engine=RetrievalEngine(store:store,apple:embedder)
        let generation=searchGeneration,observe=searchWorkObserver,completed=searchWorkCompleted,registry=libraryWork
        refreshing=true
        guard let id=registry.launch(kind:.query,priority:.userInitiated,operation:{
            defer {completed?(.query)}
            try await Task.sleep(nanoseconds:150_000_000);try Task.checkCancellation()
            try await observe?(.query);try Task.checkCancellation()
            let result=try await engine.search(filter,mode:mode,configuration:configuration,interpretQuery:interpret,now:now,detail:.preview)
            try await observe?(.queryRead);try Task.checkCancellation();return result
        },completion:{[weak self] outcome,cancelled in
            guard let self,self.searchGeneration==generation else {return}
            self.refreshTask=nil;self.refreshing=false
            guard !cancelled,self.libraryWorkAvailable else {return}
            switch outcome {
            case .success(let result):
                self.hits=result.hits;self.resolvedSearch=result.resolution;self.searchMS=result.duration*1000;self.searchStrategy=result.strategy ?? "";self.searchWarnings=result.warnings
                if self.pendingRefresh {self.pendingRefresh=false;self.refresh()}
            case .failure(is CancellationError):break
            case .failure(let error as QuerySyntaxError):self.hits=[];self.resolvedSearch=nil;self.searchWarnings=[];self.searchInputError=error.localizedDescription;self.searchMS=0;self.searchStrategy=""
            case .failure(let error):if mode == .visual {self.hits=[];self.searchWarnings=[error.localizedDescription]}else {self.errorMessage=error.localizedDescription}
            }
        }) else {refreshing=false;return}
        refreshTask=Task {await registry.wait(for:id)}
    }
    var hasPendingStatistics:Bool {statisticsTask != nil || diskUsageTask != nil}
    func refreshStatistics(force: Bool,observeWorker:(@Sendable ()throws->Void)?=nil,observeStorage:(@Sendable ()throws->Void)?=nil,statisticsCompleted:(@Sendable ()->Void)?=nil,storageCompleted:(@Sendable ()->Void)?=nil) {
        guard libraryWorkAvailable else {return}
        if statisticsTask != nil { if force { statisticsPending = true }; return }
        guard force || Date().timeIntervalSince(statisticsUpdatedAt) >= 5 else { return }
        let store=self.store,generation=libraryOperationGeneration
        statisticsTask=libraryWork.launch(kind:.statistics,operation:{
            defer {statisticsCompleted?()};try observeWorker?();try Task.checkCancellation();return try store.stats(includeDiskUsage:false)
        }) {outcome,cancelled in
            self.statisticsTask=nil
            let pending=self.statisticsPending;self.statisticsPending=false
            guard !cancelled,self.libraryOperationGeneration==generation,self.libraryWorkAvailable else {return}
            switch outcome {
            case .success(var value):value.bytes=self.stats.bytes;self.stats=value;self.statisticsUpdatedAt=Date()
            case .failure(let error):self.errorMessage=error.localizedDescription
            }
            if pending {self.refreshStatistics(force:true)}
        }
        // Storage traversal is independent of both query publication and SQL
        // counts. Coalesce it across captures/keystrokes, including large stores.
        refreshStorageEstimate(observeWorker:observeStorage,observeCompletion:storageCompleted)
    }
    func invalidateStorageEstimate() { storageGeneration = UUID(); storageUpdatedAt = nil }
    private func refreshStorageEstimate(observeWorker:(@Sendable ()throws->Void)?=nil,observeCompletion:(@Sendable ()->Void)?=nil) {
        guard libraryWorkAvailable else {return}
        guard diskUsageTask == nil, storageUpdatedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        let store=self.store,generation=storageGeneration,libraryGeneration=libraryOperationGeneration
        diskUsageTask=libraryWork.launch(kind:.storage,operation:{
            defer {observeCompletion?()};try observeWorker?();try Task.checkCancellation();return try store.storageUsageBytes()
        }) {outcome,cancelled in
            self.diskUsageTask=nil
            guard !cancelled,self.libraryOperationGeneration==libraryGeneration,self.libraryWorkAvailable else {return}
            switch outcome {
            case .success(let bytes):
                if generation==self.storageGeneration {self.stats.bytes=bytes;self.storageUpdatedAt=Date()}
                else {self.refreshStorageEstimate()}
            case .failure(let error):self.errorMessage=error.localizedDescription
            }
        }
    }
    func prepareMeetingBrief(_ event:MeetingOccurrence) {
        guard !store.isClosed,!libraryRetired,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup else {return}
        guard !asking else {errorMessage="Finish or cancel the current answer before preparing a meeting brief.";return}
        do {
            let prompt=try event.briefQuestion(policy:settings.privacy,includeParticipants:settings.meetings.includeParticipants)
            newChat();section="Ask";query="";appFilter="All apps";range="30 days";entityScope=nil;calendarSlice=nil;calendarSliceZone=nil;interpretQuery=false
            ask(prompt,interpretation:false,evidencePolicy:settings.privacy)
        }catch {errorMessage="This meeting is excluded by the current privacy policy."}
    }
    enum AnswerOperationPhase:Sendable {case started,answerReady}
    func ask(_ prompt: String? = nil, summarize: Bool = false, interpretation:Bool?=nil,evidencePolicy:PrivacyPolicy?=nil,observeWorker:(@Sendable (AnswerOperationPhase)throws->Void)?=nil,observeCompletion:(@Sendable ()->Void)?=nil) {
        guard libraryWorkAvailable,!libraryWipe.busy else {return}
        let text = settings.privacy.sanitize(prompt ?? question).text
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !asking else { return }
        answerInputError = nil;answerStatus=nil;savedAnswerID=nil
        if prompt != nil { question = text }
        let now = Date(), sessionID = currentChatID, interpret = interpretation ?? interpretQuery
        let f = filter(at:now)
        let config = settings.ai, searchConfig = settings.search,store=self.store,embedder=self.embedder,generation=libraryOperationGeneration
        let history = summarize ? [] : ConversationContext.questions(chatTurns), policy = settings.privacy
        asking = true
        libraryWork.launch(kind:.answer,operation:{
            try observeWorker?(.started);try Task.checkCancellation()
            let result=try await AnswerEngine(store:store,embedder:embedder).answer(text,configuration:config,filter:f,summarize:summarize,searchConfiguration:searchConfig,previousQuestions:history,interpretQuery:interpret,now:now,evidencePolicy:evidencePolicy)
            try observeWorker?(.answerReady);try Task.checkCancellation()
            // Serialize current-policy admission with settings/retirement. The
            // actual worker remains owned through this hop and any completion.
            let saved=try await MainActor.run { ()throws->(String,ChatTurn) in
                try Task.checkCancellation()
                guard self.libraryOperationGeneration==generation,self.libraryWorkAvailable else {throw CancellationError()}
                let turn=try store.saveChatTurn(sessionID:sessionID,question:text,answer:result,filter:f,policy:policy)
                return (turn.sessionID,turn)
            }
            observeCompletion?();return saved
        }) {outcome,cancelled in
            self.asking=false
            guard self.libraryOperationGeneration==generation,!self.libraryRetired else {return}
            switch outcome {
            case .success(let (targetID,turn)):
                guard !cancelled,self.libraryWorkAvailable else {self.savedAnswerID=targetID;self.answerStatus="Answer saved before cancellation.";return}
                self.currentChatID=targetID;self.answer=turn.answer;if self.question==text {self.question=""};self.refreshChats()
            case .failure(let error):
                if cancelled || error is CancellationError {self.answerStatus="Answer cancelled."}
                else if let syntax=error as? QuerySyntaxError {self.answerInputError=syntax.localizedDescription}
                else {self.errorMessage=error.localizedDescription}
            }
        }
    }
    func reviewDraft(_ answer:Answer) {
        voice.cancel()
        guard !store.isClosed,answer.sources.count<=60 else {errorMessage="This answer cannot be drafted from the current library.";return}
        let proofs=answer.sources.map {($0.id,$0.memory.evidenceHash)},store=self.store
        drafting.review(answer) { [weak self] in
            guard let self,!store.isClosed else {throw OSwindError.unavailable("The source library is closed.")}
            let policy=self.settings.privacy
            let validation=Task.detached(priority:.utility) {
                for (id,revision) in proofs {
                    try Task.checkCancellation()
                    guard let source=try store.get(id),source.evidenceHash==revision,
                          policy.exclusion(app:source.bundleID,title:source.title,url:source.url,isBrowser:WindowContext.isBrowser(bundle:source.bundleID))==nil else {
                        throw OSwindError.unavailable("Draft evidence changed, was removed or is now excluded. Ask again before copying or inserting.")
                    }
                }
            }
            try await withTaskCancellationHandler {try await validation.value} onCancel:{validation.cancel()}
        }
    }
    func cancelAnswer() {libraryWork.cancel(kinds:[.answer]);if asking,!libraryRetired {answerStatus="Cancelling; waiting for current work to stop…"}}
    func newChat() { guard !asking else { return }; currentChatID = nil; chatTurns = []; answer = nil; question = "";answerStatus=nil;savedAnswerID=nil }
    func selectChat(_ id: String) { guard !asking else { return }; currentChatID = id; question = "";answerStatus=nil;savedAnswerID=nil;refreshChats() }
    func reviewSavedAnswer() {guard libraryWorkAvailable,!asking,let id=savedAnswerID else {return};selectChat(id)}
    func refreshChats() {
        guard libraryWorkAvailable else {return}
        do { chats = try store.chats(); if let id = currentChatID { if try store.chat(id) != nil { chatTurns = try store.chatTurns(id); answer = chatTurns.last?.answer } else { currentChatID = nil; chatTurns = []; answer = nil } } }
        catch { errorMessage = error.localizedDescription }
    }
    func deleteCurrentChat() { guard libraryWorkAvailable,!asking, let id = currentChatID else { return }; do { try store.deleteChat(id); newChat(); refreshChats() } catch { errorMessage = error.localizedDescription } }
    func exportChat() {
        guard libraryWorkAvailable,let id = currentChatID else { return }
        do { guard let session = try store.chat(id) else { return }; let text = ConversationContext.markdown(session,turns:try store.chatTurns(id,limit:1000)); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-conversation.md"; if panel.runModal() == .OK,libraryWorkAvailable,let url = panel.url { try text.write(to:url,atomically:true,encoding:.utf8); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) } } catch { errorMessage = error.localizedDescription }
    }
    func saveAnswer(_ value:Answer?=nil,observeWorker:(@Sendable ()throws->Void)?=nil,observeCompletion:(@Sendable ()->Void)?=nil) {
        guard libraryWorkAvailable,!libraryWipe.busy,!savingRecap,let result=value ?? answer,!result.sources.isEmpty else {return}
        savingRecap=true;recapSaveStatus="Saving a source-linked recap…"
        let store=self.store,embedder=self.embedder,policy=settings.privacy,generation=libraryOperationGeneration
        libraryWork.launch(kind:.recap,operation:{
            try observeWorker?();try Task.checkCancellation()
            let memory=try store.saveRecap(result,title:"Recap · \(Date().formatted(date:.abbreviated,time:.shortened))",policy:policy,embedder:embedder)
            observeCompletion?();return memory
        }) {outcome,cancelled in
            self.savingRecap=false
            guard self.libraryOperationGeneration==generation,!self.libraryRetired else {return}
            switch outcome {
            case .success(let memory):
                self.recapSaveStatus=cancelled ? "Recap committed before cancellation. Refresh to review it.":"Saved to Recaps with \(result.sources.count) original \(result.sources.count==1 ? "source":"sources")."
                if !cancelled {self.captured(memory)}
            case .failure(let error):
                self.recapSaveStatus=cancelled ? "Recap save cancelled.":"Recap save did not finish."
                if !cancelled {self.errorMessage=error.localizedDescription}
            }
        }
    }
    func addNote(_ text:String,title:String="Quick note",kind:MemoryKind = .note,observeWorker:(@Sendable ()throws->Void)?=nil,observeCompletion:(@Sendable ()->Void)?=nil) {
        guard libraryWorkAvailable,!libraryWipe.busy else {return}
        let clean=settings.privacy.sanitize(text).text,embedder=self.embedder,store=self.store,generation=libraryOperationGeneration
        libraryWork.launch(kind:.note,operation:{
            try observeWorker?();try Task.checkCancellation()
            var memory=Memory(kind:kind,app:"OSwind",title:title,text:clean)
            memory.embedding=embedder.embed(memory.searchableText);memory.embeddingModel=memory.embedding==nil ? nil:embedder.modelID
            try Task.checkCancellation();try store.insert(memory);observeCompletion?();return memory
        }) {outcome,cancelled in
            guard self.libraryOperationGeneration==generation,!self.libraryRetired else {return}
            switch outcome {
            case .success(let memory):if !cancelled {self.captured(memory)}
            case .failure(let error):if !cancelled {self.errorMessage=error.localizedDescription}
            }
        }
    }
    enum MCPResultSavePhase:Sendable {case started,settingsCaptured}
    func saveMCPResult(_ draft:MCPResultSourceDraft,observeWorker:(@Sendable (MCPResultSavePhase)throws->Void)?=nil,scannerFactory:@escaping @Sendable (PIIImportConfiguration) async throws->PIIImportScanner={try await $0.scanner()}) async throws ->CollectorImportResult {
        guard !store.isClosed,!libraryRetired,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup,!libraryTransfer.busy,!maintenanceBusy,!importingJSON else {throw OSwindError.unavailable("The library is unavailable for tool-result admission")}
        let store=self.store,embedder=self.embedder,policy=settings.privacy,pii=settings.piiImports,generation=libraryOperationGeneration
        let worker=Task.detached(priority:.utility) {()throws->(CollectorImportResult,Memory?) in
            try Task.checkCancellation();try observeWorker?(.started);try Task.checkCancellation();let activity=try store.mediaWriteLease();defer {activity.release()}
            let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
            guard snapshot.settings.privacy==policy,snapshot.settings.piiImports==pii,snapshot.settings.mcpConnections.contains(where:{$0.id==draft.profileID}) else {throw OSwindError.unavailable("Saved connection or privacy settings changed; review this result again")}
            try observeWorker?(.settingsCaptured);try Task.checkCancellation()
            let result:CollectorImportResult
            if pii.enabled {
                let scanner=try await scannerFactory(pii)
                do {result=try await store.importCollectorBatch(draft.batch,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity,scanner:scanner);await scanner.shutdown()}
                catch {await scanner.shutdown();throw error}
            }else {result=try store.importCollectorBatch(draft.batch,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity)}
            try Task.checkCancellation();return(result,result.imported>0 ? try store.get(draft.sourceID):nil)
        }
        let (result,memory)=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
        try Task.checkCancellation();guard libraryOperationGeneration==generation,!store.isClosed,!libraryRetired else {throw CancellationError()}
        if let memory {captured(memory)};return result
    }
    enum ClipboardResultSavePhase:Sendable {case started,settingsCaptured}
    func saveClipboardResult(_ draft:ClipboardTextDraft,observeWorker:(@Sendable (ClipboardResultSavePhase)throws->Void)?=nil,scannerFactory:@escaping @Sendable (PIIImportConfiguration) async throws->PIIImportScanner={try await $0.scanner()}) async throws ->CollectorImportResult {
        guard settings.clipboard.enabled,!store.isClosed,!libraryRetired,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup,!libraryTransfer.busy,!maintenanceBusy,!importingJSON else {throw OSwindError.unavailable("The library is unavailable for clipboard admission")}
        let store=self.store,embedder=self.embedder,policy=settings.privacy,pii=settings.piiImports,generation=libraryOperationGeneration
        let worker=Task.detached(priority:.utility) {()throws->(CollectorImportResult,Memory?) in
            try Task.checkCancellation();try observeWorker?(.started);try Task.checkCancellation();let activity=try store.mediaWriteLease();defer {activity.release()}
            let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
            guard snapshot.settings.privacy==policy,snapshot.settings.piiImports==pii,snapshot.settings.clipboard.enabled else {throw OSwindError.unavailable("Saved clipboard choice or privacy settings changed; this observation was discarded")}
            try observeWorker?(.settingsCaptured);try Task.checkCancellation()
            let result:CollectorImportResult
            if pii.enabled {
                let scanner=try await scannerFactory(pii)
                do {result=try await store.importCollectorBatch(draft.batch,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity,scanner:scanner);await scanner.shutdown()}
                catch {await scanner.shutdown();throw error}
            }else {result=try store.importCollectorBatch(draft.batch,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity)}
            try Task.checkCancellation();return(result,result.imported>0 ? try store.get(draft.sourceID):nil)
        }
        let (result,memory)=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
        try Task.checkCancellation();guard libraryOperationGeneration==generation,!store.isClosed,!libraryRetired else {throw CancellationError()}
        if let memory {captured(memory)};return result
    }
    func cancelExternalWorkAndWait() async {
        // Reserve the import-drain gate before yielding to either worker. A
        // detached preparation not yet holding a lease must finish too.
        jsonImportDrainers+=1;destructiveDrainers+=1;defer {jsonImportDrainers-=1;destructiveDrainers-=1}
        let importWorker=jsonImportWorker,completion=jsonImportTask;importWorker?.cancel();completion?.cancel()
        cancelDestructiveWork()
        cancelRefresh();cancelIndexing();cancelAutomaticIndexer();visualAutoResumeAllowed=false;cancelVisualIndexing()
        cancelOpeningMemory();piiScanStatusGeneration=UUID()
        historicalDetailTask?.cancel();historicalDetailTask=nil;historicalDetailGeneration=UUID()
        libraryWork.cancel()
        pendingMediaCleanup.stop()
        voice.cancel(clearDraft:true);workflow.cancel(clear:true);clipboard.stop();await tools.cancelAndWait();await clipboard.cancelAndWait();await voice.cancelAndWait();await workflow.cancelAndWait()
        if let importWorker {_ = try? await importWorker.value};if let completion {await completion.value}
        await cancelDestructiveWorkAndWait()
        await pendingMediaCleanup.cancelAndWait()
        await libraryWork.cancelAndWait()
    }
    private func cancelDestructiveWork() {
        deletionWorker?.cancel();maintenanceWorker?.cancel();deletionTask?.cancel();maintenanceTask?.cancel()
    }
    private func cancelMaintenanceWork(automaticOnly:Bool=false) {
        guard !automaticOnly || maintenanceAutomatic else {return}
        maintenanceWorker?.cancel();maintenanceTask?.cancel()
    }
    /// Both the worker and its actor completion belong to the departing library.
    /// Cancellation of this drain caller does not acknowledge unfinished work.
    func cancelDestructiveWorkAndWait() async {
        destructiveDrainers+=1;defer {destructiveDrainers-=1}
        let deletion=deletionWorker,deleted=deletionTask,maintenance=maintenanceWorker,maintained=maintenanceTask
        cancelDestructiveWork()
        if let deletion {_ = try? await deletion.value};if let maintenance {_ = try? await maintenance.value}
        if let deleted {await deleted.value};if let maintained {await maintained.value}
    }
    private var lastObservationRefresh = -Double.infinity
    private func observed(_ memory:Memory) {
        if selected?.id==memory.id {selected=memory}
        // No source/entity/embedding queue work for unchanged text. Calendar
        // has its own revision monitor; coalesce ordinary visible list refresh.
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastObservationRefresh>=3 else {return}
        lastObservationRefresh=now
        if refreshing {pendingRefresh=true}else {refresh()}
    }
    private func captured(_ memory: Memory) {
        guard libraryWorkAvailable,!libraryWipe.busy,!libraryWipe.pendingCleanup else {return}
        if settings.entityAutomaticIndex {entityMemory.enqueue(memory)}
        queueVisualIndex(memory)
        refreshStatistics(force:true)
        if refreshing { pendingRefresh = true } else { refresh() }
        guard settings.search.provider == .ollama || memory.text.utf16.count > 2400 else { return }
        guard settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { indexStatus = "GPU indexing deferred in Low Power Mode; keyword/Apple capture continues"; return }
        if pendingIndex.count >= 64 { indexStatus = "GPU index is behind capture. Rebuild to catch up."; return }
        pendingIndex.removeAll { $0.id == memory.id }; pendingIndex.append(memory)
        startAutomaticIndexer()
    }
    private func cancelAutomaticIndexer() {
        automaticIndexGeneration=UUID();automaticIndexTask?.cancel();automaticIndexTask=nil;libraryWork.cancel(kinds:[.automaticText]);pendingIndex.removeAll()
    }
    private func startAutomaticIndexer() {
        guard libraryWorkAvailable,!libraryWipe.busy,!libraryWipe.pendingCleanup,automaticIndexTask==nil,libraryWork.count(kinds:[.automaticText])==0,!pendingIndex.isEmpty else {return}
        guard settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else {indexStatus="GPU indexing deferred in Low Power Mode";return}
        let batch=Array(pendingIndex.prefix(16));pendingIndex.removeFirst(batch.count)
        let configuration=settings.search,engine=RetrievalEngine(store:store,apple:embedder),generation=automaticIndexGeneration,observe=searchWorkObserver,completed=searchWorkCompleted,registry=libraryWork
        guard let id=registry.launch(kind:.automaticText,operation:{
            defer {completed?(.automaticText)}
            try Task.checkCancellation();try await observe?(.automaticText);try Task.checkCancellation()
            return try await engine.index(batch,configuration:configuration,shouldContinue:{configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled})
        },completion:{[weak self] outcome,cancelled in
            guard let self else {return}
            if registry.count(kinds:[.automaticText])<=1 {self.automaticIndexTask=nil}
            if self.automaticIndexGeneration==generation,!cancelled,self.libraryWorkAvailable,case .failure(let error)=outcome,!(error is CancellationError) {self.indexStatus=error.localizedDescription;self.pendingIndex.removeAll()}
            // The completing job leaves the registry after this synchronous
            // callback. Resume the current queue on the next actor turn.
            Task {@MainActor [weak self] in self?.startAutomaticIndexer()}
        }) else {return}
        automaticIndexTask=Task {await registry.wait(for:id)}
    }
    func startModelServer() {
        guard !startingModelServer else { return }; startingModelServer = true
        Task { do { modelStatus = try await LocalModelServer.shared.start(endpoint:settings.search.endpoint); inspectLocalModels() } catch { modelStatus = error.localizedDescription }; startingModelServer = false }
    }
    func inspectLocalModels() {
        let endpoint = settings.search.endpoint; installedModels = []; modelStatus = "Checking local server…"
        Task { do { let models = try await OllamaClient.shared.models(endpoint:endpoint); let runtime = try await OllamaClient.shared.runtime(endpoint:endpoint); guard settings.search.endpoint == endpoint else { return }; installedModels = models; localRuntime = runtime; modelStatus = models.isEmpty ? "Server ready; download a model below" : "\(models.count) local models available" } catch { modelStatus = "Local server unavailable: " + error.localizedDescription } }
    }
    func downloadModel(_ name: String) {
        guard pullingModel == nil else { return }; pullingModel = name; pullProgress = nil; let endpoint = settings.search.endpoint
        pullTask = Task {
            do { try await OllamaClient.shared.pull(name,endpoint:endpoint) { progress in Task { @MainActor in self.pullProgress = progress } }; modelStatus = "Downloaded \(name)" }
            catch is CancellationError { modelStatus = "Download request cancelled; cached layers can be resumed" }
            catch { modelStatus = error.localizedDescription }
            pullingModel = nil; pullProgress = nil; inspectLocalModels()
        }
    }
    func cancelModelDownload() { pullTask?.cancel() }
    private func finishTextIndex(_ outcome:Result<String,Error>,generation:UUID,cancelled:Bool,completeProgress:Bool) {
        let last=libraryWork.count(kinds:[.textRebuild,.fastIndex])<=1
        if last {indexTask=nil;indexing=false}
        let invalidated=indexGeneration != generation || cancelled
        if last,libraryStatusAvailable,invalidated,indexStatus.hasPrefix("Stopping") {indexStatus="Indexing stopped. Build the selected index to continue."}
        guard libraryWorkAvailable,!invalidated else {return}
        switch outcome {
        case .success(let message):indexStatus=message;if completeProgress {indexProgress=1};refresh()
        case .failure(is CancellationError):indexStatus="Indexing stopped."
        case .failure(let error):indexStatus=error.localizedDescription
        }
    }
    func rebuildIndex() {
        guard libraryWorkAvailable,!libraryWipe.busy,!libraryWipe.pendingCleanup,!indexing,libraryWork.count(kinds:[.textRebuild,.fastIndex])==0 else {return}
        let configuration=settings.search
        guard configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else {indexStatus="Disable Low Power Mode or allow indexing below";return}
        indexGeneration=UUID();let generation=indexGeneration,engine=RetrievalEngine(store:store,apple:embedder),observe=searchWorkObserver,completed=searchWorkCompleted,registry=libraryWork
        indexing=true;indexProgress=0;indexStatus="Preparing the selected local model…"
        guard let id=registry.launch(kind:.textRebuild,operation:{[weak self] in
            defer {completed?(.textRebuild)}
            try Task.checkCancellation();try await observe?(.textRebuild);try Task.checkCancellation()
            let final=try await engine.rebuild(configuration:configuration,shouldContinue:{configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled}) {state in
                Task {@MainActor [weak self] in guard let self,self.libraryWorkAvailable,self.indexGeneration==generation,self.indexing else {return};self.indexProgress=state.total>0 ? min(1,Double(state.indexed)/Double(state.total)):1;self.indexStatus="\(state.indexed) / \(state.total) memories indexed"}
            }
            return final.indexed==final.total ? "Search index ready · \(final.indexed) memories":"Index pass complete · \(final.indexed)/\(final.total); new captures may still be indexing"
        },completion:{[weak self] outcome,cancelled in self?.finishTextIndex(outcome,generation:generation,cancelled:cancelled,completeProgress:false)}) else {indexing=false;return}
        indexTask=Task {await registry.wait(for:id)}
    }
    private func watchFastIndex(_ generation:UUID)->Task<Void,Never> {
        Task {[weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:500_000_000)}catch {return}
                guard let self,self.libraryWorkAvailable,self.indexGeneration==generation,self.indexing else {return}
                let state=self.store.searchIndexStatus;self.indexStatus=state.message+(state.total>0 ? " · \(state.indexed)/\(state.total)":"")
                if state.total>0 {self.indexProgress=min(1,Double(state.indexed)/Double(state.total))}
            }
        }
    }
    func prepareFastIndex() {
        guard libraryWorkAvailable,!libraryWipe.busy,!libraryWipe.pendingCleanup,!indexing,libraryWork.count(kinds:[.textRebuild,.fastIndex])==0 else {return}
        let configuration=settings.search,localEmbedder=embedder,store=self.store,observe=searchWorkObserver,completed=searchWorkCompleted,registry=libraryWork
        guard configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else {indexStatus="Disable Low Power Mode or allow indexing below";return}
        indexGeneration=UUID();let generation=indexGeneration
        indexing=true;indexProgress=0;indexStatus="Preparing fast retrieval…"
        let observer=watchFastIndex(generation)
        guard let id=registry.launch(kind:.fastIndex,operation:{
            defer {observer.cancel();completed?(.fastIndex)}
            try Task.checkCancellation();try await observe?(.fastIndex);try Task.checkCancellation()
            let identity:String,dimensions:Int
            if configuration.provider == .ollama {let batch=try await OllamaClient.shared.embed(["search index identity"],configuration:configuration);identity=batch.modelID;dimensions=batch.vectors[0].count}
            else {
                let worker=Task.detached(priority:.utility) {localEmbedder.embed("search index identity")}
                let vector=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
                try Task.checkCancellation();guard let vector else {throw OSwindError.unavailable("Apple sentence embeddings are unavailable")};identity=localEmbedder.modelID;dimensions=vector.count
            }
            try Task.checkCancellation()
            let state=try await store.buildSearchIndex(modelID:identity,dimensions:dimensions,allowLowPower:configuration.indexOnLowPower)
            return "Fast retrieval ready · \(state.indexed) vectors"
        },completion:{[weak self] outcome,cancelled in self?.finishTextIndex(outcome,generation:generation,cancelled:cancelled,completeProgress:true)}) else {observer.cancel();indexing=false;return}
        indexTask=Task {await registry.wait(for:id)}
    }
    func cancelIndexing() {
        indexGeneration=UUID();indexTask?.cancel();libraryWork.cancel(kinds:[.textRebuild,.fastIndex]);store.cancelSearchIndexBuild(pauseAutomatic:true)
        indexing=libraryWork.count(kinds:[.textRebuild,.fastIndex])>0
        if indexing {indexStatus="Stopping local search work…"}
    }
    func favorite(_ memory: Memory) { guard libraryWorkAvailable else {return};guard memory.originalEvidence==nil else {errorMessage="Original evidence is read-only.";return};do { try store.setFavorite(memory.id,value:!memory.favorite); if selected?.id == memory.id { selected = try store.get(memory.id) }; refresh() } catch { errorMessage = error.localizedDescription } }
    // Observers are internal test seams. Only pre-work observation may throw;
    // a postcommit observation must not turn real deletion into a false failure.
    func delete(_ memory:Memory,observeWorker:(@Sendable ()throws->Void)?=nil,observeCompletion:(@Sendable ()->Void)?=nil) {
        guard !libraryRetired,!store.isClosed,destructiveDrainers==0,!hasPendingDestructiveWork else {return}
        guard memory.originalEvidence==nil else {errorMessage="Original evidence is read-only. Delete its source from the library to erase it and dependent citations.";return}
        guard !libraryWipe.busy,deletingID==nil,!maintenanceBusy else {return};drafting.clear();tools.suspend();clipboard.invalidate();workflow.cancel(clear:true);deletingID=memory.id;deletionStatus="Deleting source and checking retained media…"
        if openingMemoryID==memory.id {cancelOpeningMemory()};if selected?.id==memory.id {selected=nil}
        let store=self.store,generation=libraryOperationGeneration
        deletionTask=Task {
            defer {deletionWorker=nil;deletionTask=nil;deletingID=nil}
            do {
                await workflow.cancelAndWait()
                try Task.checkCancellation()
                guard generation==libraryOperationGeneration,!libraryRetired else {throw CancellationError()}
                let worker=Task.detached(priority:.utility) {try observeWorker?();try Task.checkCancellation();let result=try store.delete(memory.id);observeCompletion?();return result}
                deletionWorker=worker
                let result=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                guard generation==libraryOperationGeneration,!libraryRetired else {return}
                deletionStatus="Removed \(result.sources) \(result.sources==1 ? "source":"sources") · \(result.historicalVersions) original versions · \(result.sharedMedia) shared \(result.sharedMedia==1 ? "file":"files") kept · \(result.pendingMedia) queued for file cleanup"
                if !result.warnings.isEmpty {errorMessage="The source deletion committed. "+result.warnings.joined(separator:" ")}
                invalidateCommittedErasure(result,discardVisible:Task.isCancelled)
                guard !Task.isCancelled else {return}
                refresh(forceStatistics:true);refreshChats()
            } catch is CancellationError {if generation==libraryOperationGeneration,!libraryRetired {deletionStatus="Deletion cancelled before publication."}}
            catch {guard generation==libraryOperationGeneration,!libraryRetired else {return};deletionStatus="Source was not deleted.";errorMessage=error.localizedDescription}
        }
    }
    func maintain(automatic:Bool=false,observeWorker:(@Sendable ()throws->Void)?=nil,observeCompletion:(@Sendable ()->Void)?=nil) {
        guard !libraryRetired,!store.isClosed,destructiveDrainers==0,!hasPendingDestructiveWork else {return}
        guard !automatic || !libraryWipe.pendingCleanup else {return}
        guard !libraryWipe.busy,!maintenanceBusy,deletingID==nil else {return}
        if automatic {guard housekeepingActive,!showOnboarding,!workflow.busy else {return}}
        let store=self.store,policy=settings.privacy,allowLowPower=settings.search.indexOnLowPower,shouldPrune = !automatic || settings.automaticMaintenance,generation=libraryOperationGeneration
        if shouldPrune {workflow.cancel(clear:true)}
        maintenanceAutomatic=automatic;maintenanceBusy=true;maintenanceStatus=shouldPrune ? "Checking retention and retained media…":"Checking search cache…"
        maintenanceTask=Task {
            defer {maintenanceWorker=nil;maintenanceTask=nil;maintenanceBusy=false;maintenanceAutomatic=false}
            do {
                if shouldPrune {await workflow.cancelAndWait()}
                try Task.checkCancellation()
                guard generation==libraryOperationGeneration,!libraryRetired else {throw CancellationError()}
                let worker=Task.detached(priority:.utility) { () -> (RetentionCleanupResult?,String?) in
                    try observeWorker?();try Task.checkCancellation()
                    let report=shouldPrune ? try store.pruneHistory(before:Date().addingTimeInterval(-Double(policy.retentionDays)*86400),maxBytes:Int64(policy.maxStorageGB)*1_000_000_000):nil
                    observeCompletion?()
                    if Task.isCancelled {return (report,nil)}
                    do {try store.checkpointSearchIndexIfIdle(allowLowPower:allowLowPower);return (report,nil)}
                    catch {return (report,"Search cache maintenance did not finish: "+error.localizedDescription)}
                }
                maintenanceWorker=worker
                let (result,indexError)=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                guard generation==libraryOperationGeneration,!libraryRetired else {return}
                if let result {
                    let budget=result.budgetMet==false ? "Storage target not reached.":"Storage target met."
                    maintenanceStatus="Removed \(result.erasure.sources) \(result.erasure.sources==1 ? "source":"sources") · \(result.erasure.historicalVersions) original versions · \(result.erasure.pendingMedia) media files queued for cleanup. "+budget+" "+result.erasure.warnings.joined(separator:" ")
                } else {maintenanceStatus="Automatic retention is off."}
                if let indexError {maintenanceStatus += " "+indexError}
                if let result {invalidateCommittedErasure(result.erasure,discardVisible:Task.isCancelled)}else {invalidateStorageEstimate()}
                guard !Task.isCancelled else {return}
                refresh(forceStatistics:true);refreshChats();await catchUpIndex()
            } catch is CancellationError {if generation==libraryOperationGeneration,!libraryRetired {maintenanceStatus="Cleanup cancelled."}}
            catch {guard generation==libraryOperationGeneration,!libraryRetired else {return};maintenanceStatus="Cleanup did not complete: "+error.localizedDescription;if !automatic {errorMessage=maintenanceStatus}}
        }
    }
    private func invalidateCommittedErasure(_ result:HistoryErasureResult,discardVisible:Bool) {
        activity.forgetCounts();invalidateStorageEstimate()
        guard result.sources>0 || result.historicalVersions>0 || result.conversationTurns>0 else {return}
        drafting.clear();tools.suspend();clipboard.invalidate();cancelAnswer();answer=nil
        // A cancelled completion cannot start fresh IO to revalidate previews.
        // Drop the old references locally; the next deliberate refresh can read
        // the surviving graph. A real committed result is still shown above.
        if discardVisible {selected=nil;selectedVisual=nil;hits=[];chatTurns=[];chats=[];currentChatID=nil}
    }
    private func catchUpIndex() async {
        let configuration = settings.search,generation=libraryOperationGeneration
        guard !libraryRetired,!store.isClosed,!Task.isCancelled,!indexing, configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        if configuration.provider == .apple {
            if (try? store.passageBacklog(modelID:embedder.modelID,filter:SearchFilter())) ?? 0 > 0 { rebuildIndex() }
            return
        }
        do {
            let model = try await OllamaClient.shared.models(endpoint:configuration.endpoint).first { $0.name == configuration.model || $0.name == configuration.model + ":latest" }
            guard generation==libraryOperationGeneration,!libraryRetired,!store.isClosed,!Task.isCancelled,settings.search == configuration, let model else { return }
            let prefix = "ollama:\(model.name)@\(model.digest):desktop-v1:"
            let indexes = try store.semanticIndexes().filter { $0.key.hasPrefix(prefix) }
            let indexed = indexes.values.max() ?? 0
            let pendingPassages = try indexes.keys.contains { try store.passageBacklog(modelID:$0,filter:SearchFilter())>0 }
            if indexed < (try store.matchingCount()) || pendingPassages { rebuildIndex() }
        } catch {guard generation==libraryOperationGeneration,!libraryRetired,!Task.isCancelled else {return};indexStatus = "Index catch-up waiting for the local model server"}
    }
    func wipeLocalLibrary(retry:Bool=false) {
        guard !libraryRetired,!store.isClosed,!libraryWipe.busy,!maintenanceBusy,deletingID==nil,!libraryTransfer.busy else {return}
        let resumeCleanup=pendingMediaCleanup.active
        prepareForLibrarySwitch()
        // This explicit wipe owns its quiet preferences, after cancellation has
        // stopped the old workspace. Ordinary retired bindings remain denied.
        var quiet=settings
        quiet.captureOnLaunch=false;quiet.apiEnabled=false;quiet.routinesEnabled=false;quiet.entityAutomaticIndex=false;quiet.meetings = .init()
        assignInternalSettings(quiet);applySettingsToControllers()
        do {try quiet.save(root:store.root)}catch {errorMessage=error.localizedDescription}
        let generation=libraryOperationGeneration
        libraryWipe.run(store:store,retry:retry,before:{[workflow,pendingMediaCleanup,libraryWork] in await workflow.cancelAndWait();await pendingMediaCleanup.cancelAndWait();await libraryWork.cancelAndWait()}) {[weak self] result in
            guard let self,self.libraryOperationGeneration==generation else {return}
            self.libraryRetired=false;self.routines.reload();self.answer=nil;self.chatTurns=[];self.currentChatID=nil;self.selected=nil;self.hits=[]
            self.invalidateStorageEstimate();self.refresh(forceStatistics:true);self.refreshChats();self.startHousekeeping();if resumeCleanup {self.pendingMediaCleanup.start()}
        } onFailure: {[weak self] in guard let self,self.libraryOperationGeneration==generation else {return};self.libraryRetired=false;self.startHousekeeping();if resumeCleanup {self.pendingMediaCleanup.start()}}
    }
    func pauseAll(discardReplay:Bool=false,manualMeetingPause:Bool=true) {
        if isCollecting {resumeOnlyClipboard=clipboard.running && !isCapturing && !meetings.active;resumeMeetingsAfterPause=meetings.active;resumeScreenWithMeetings=capture.running}
        pauseTimer?.invalidate();pauseTimer=nil;pauseUntil=nil;capture.pause(discardReplay:discardReplay);audio.stop()
        if manualMeetingPause {meetings.pause()}else {meetings.sleep()};tools.suspend();clipboard.stop();voice.cancel(clearDraft:true);workflow.cancel()
    }
    func pauseForHistoryErasure() {
        // Privacy confirmation revokes earlier pending source work as well as
        // collection. No previously read result may return to the cleared UI.
        cancelRefresh();cancelIndexing();cancelAutomaticIndexer();cancelJSONImport();cancelAudioImport();libraryWork.cancel()
        hits.removeAll();resolvedSearch=nil;searchWarnings.removeAll();searchInputError=nil
        drafting.clear()
        entityMemory.clear();entityScope=nil
        activity.deactivate(clear:true)
        // Stop readers holding media reservations before asking erasure to take
        // an exclusive reservation. Wake/power callbacks must not restart them.
        visualAutoResumeAllowed=false;cancelVisualIndexing()
        pauseAll(discardReplay:true);cancelAnswer();routines.cancel();cancelOpeningMemory();selected=nil;answer=nil
    }
    func pauseFor(minutes: Int) {
        let screenWasRunning = capture.running, audioWasRunning = audio.running, meetingsWereRunning=meetings.active,clipboardWasRunning=clipboard.running
        pauseAll(); pauseUntil = Date().addingTimeInterval(Double(minutes)*60)
        pauseTimer = Timer.scheduledTimer(withTimeInterval:Double(minutes)*60,repeats:false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.pauseUntil = nil;if clipboardWasRunning {self.clipboard.start()};if meetingsWereRunning {self.meetings.resume()}; if screenWasRunning { self.capture.start() }; if audioWasRunning && !self.voice.busy && !SessionState.locked { await self.audio.start() } }
        }
    }
    var collectionStatus:String {
        if voice.busy {return voice.status}
        if workflow.busy {return workflow.status}
        if audio.running {return audio.status+(clipboard.running ? " · Clipboard on":"")}
        if capture.running {return capture.status+(clipboard.running ? " · Clipboard on":"")}
        if clipboard.running {return "Clipboard · "+clipboard.status}
        return capture.status
    }
    var isCapturing: Bool { capture.running || audio.running }
    var isCollecting:Bool {isCapturing || meetings.active || clipboard.running}
    var hasPausableWork:Bool {isCollecting || tools.busy || clipboard.busy || voice.busy || workflow.busy}
    func captureNow() async {guard !libraryWipe.busy else {return};await capture.captureOnce(manual:true)}
    func toggleAudio() async {guard !libraryWipe.busy,!voice.busy else {return};if audio.running {audio.finish()} else {await audio.start()}}
    func toggleCapture() {
        guard !libraryWipe.busy else {return};pauseTimer?.invalidate();pauseUntil=nil
        if hasPausableWork {pauseAll()}
        else {
            let calendar=resumeMeetingsAfterPause,screen=resumeScreenWithMeetings,clipboardOnly=resumeOnlyClipboard
            resumeMeetingsAfterPause=false;resumeScreenWithMeetings=false;resumeOnlyClipboard=false
            if (!calendar && !clipboardOnly) || screen {capture.start()}
            if settings.clipboard.enabled {clipboard.start()}
            if calendar {meetings.resume()}
        }
    }
    func installNativeModel(_ kind:NativeModelKind,cache:URL?=nil,verifyOnly:Bool=false) {
        let speech=settings.speech,diarization=settings.diarization
        nativeModels.start(kind,cache:cache,verifyOnly:verifyOnly) { [weak self] result in
            guard let self else{return}
            let unchanged=kind == .parakeet ? self.settings.speech==speech:self.settings.diarization==diarization
            guard unchanged,!self.audio.hasActiveWork,!self.importingAudio,!self.voice.busy else {
                self.nativeModels.message((result.reused ? "Verified.":"Installed.")+" Select Use model after current audio work finishes or to apply your new choice.",for:kind);return
            }
            self.useNativeModel(result)
        }
    }
    func useNativeModel(_ result:NativeModelInstallation) {
        guard !audio.hasActiveWork,!importingAudio,!voice.busy else {nativeModels.message("Finish current audio work before changing models.",for:result.kind);return}
        switch result.kind {
        case .parakeet:
            var value=settings.speech;value.engine = .parakeet;value.modelDirectory=result.directory.path;settings.speech=value
        case .speakers:
            guard SpeakerDiarizer.supported else {nativeModels.message("Speaker labels require macOS 15 or later.",for:.speakers);return}
            var value=settings.diarization;value.modelDirectory=result.directory.path;value.enabled=true;settings.diarization=value
        }
        nativeModels.message("Ready for local transcription.",for:result.kind)
    }
    enum AudioImportPhase:Sendable {case started,clipPrepared,beforeAdmission}
    func importAudio() {
        guard libraryWorkAvailable,!libraryWipe.busy else {return}
        guard !voice.busy else {audioImportStatus="Finish voice typing before importing audio.";return}
        guard !importingAudio else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.audio]; panel.allowsMultipleSelection=false; panel.message="Transcribe this file locally. Clip retention follows your Audio setting."
        guard panel.runModal() == .OK,libraryWorkAvailable,!libraryWipe.busy,!voice.busy,!importingAudio,let file=panel.url else { return }
        importAudioFile(file)
    }
    func importAudioFile(_ file:URL,recognizer:SpeechRecognizer?=nil,speakers:SpeakerDiarizer?=nil,observePhase:(@Sendable (AudioImportPhase)async throws->Void)?=nil,observeCompletion:(@Sendable ()async->Void)?=nil,observeAdmission:(@Sendable ()->Void)?=nil) {
        guard libraryWorkAvailable,!libraryWipe.busy,!voice.busy,!importingAudio else {return}
        importingAudio=true; audioImportStatus="Preparing audio…"; let configuration=settings
        let recognizer=recognizer ?? audio.recognizer,speakers=speakers ?? audio.speakers,store=self.store,embedder=self.embedder,generation=libraryOperationGeneration
        libraryWork.launch(kind:.audioImport,operation:{
                func progress(_ text:String)async throws {
                    try await MainActor.run {
                        try Task.checkCancellation();guard self.libraryOperationGeneration==generation,self.libraryWorkAvailable else {throw CancellationError()}
                        self.audioImportStatus=text
                    }
                }
                try Task.checkCancellation();try await observePhase?(.started);try Task.checkCancellation()
                if configuration.diarization.enabled {
                    guard SpeakerDiarizer.supported else { throw OSwindError.unavailable("Speaker labels require macOS 15 or later") }
                    _ = try configuration.diarization.localDirectory()
                }
                let clip=try await AudioClipSnapshot.prepare(file,store:store); defer { withExtendedLifetime(clip) {} }
                try await observePhase?(.clipPrepared);try Task.checkCancellation()
                try await progress("Transcribing locally…")
                var transcript=try await recognizer.transcribe(file:clip.speechFile,settings:configuration,timeout:1800,workspaceParent:clip.speechFile.deletingLastPathComponent())
                try Task.checkCancellation(); transcript=try transcript.bounded(toSourceDuration:clip.duration)
                if configuration.diarization.enabled {
                    try await progress("Identifying speakers locally…")
                    transcript=try await speakers.annotate(transcript,file:clip.speechFile,configuration:configuration.diarization)
                }
                try Task.checkCancellation()
                try await observePhase?(.beforeAdmission);try Task.checkCancellation()
                let current=try await MainActor.run { ()throws->AppSettings in
                    try Task.checkCancellation();guard self.libraryOperationGeneration==generation,self.libraryWorkAvailable else {throw CancellationError()};return self.settings
                }
                let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
                guard snapshot.settings.privacy==current.privacy,snapshot.settings.retainAudio==current.retainAudio else {throw OSwindError.unavailable("Saved audio privacy or retention changed. Retry with current settings.")}
                observeAdmission?()
                let memory=try AudioAdmission.save(transcript,file:clip.file,store:store,settings:current,timestamp:Date(),source:"Imported audio",title:file.deletingPathExtension().lastPathComponent,sessionID:UUID().uuidString,recordedLive:false,embedder:embedder,admission:clip.mediaActivity,settingsSnapshot:snapshot)
                await observeCompletion?();return memory
        }) {outcome,cancelled in
            self.importingAudio=false
            guard self.libraryOperationGeneration==generation,!self.libraryRetired else {return}
            switch outcome {
            case .success(let memory):
                if cancelled || !self.libraryWorkAvailable {self.audioImportStatus="Transcript saved before cancellation. Open Conversations to review it."}
                else {self.captured(memory);self.audioImportStatus="Transcript saved · find it in Conversations"}
            case .failure(let error):self.audioImportStatus=cancelled || error is CancellationError ? "Import cancelled":error.localizedDescription
            }
        }
    }
    func cancelAudioImport() {libraryWork.cancel(kinds:[.audioImport]);if importingAudio,!libraryRetired {audioImportStatus="Cancelling; waiting for local audio work to stop…"}}
    func exportData() {guard libraryWorkAvailable else {return};pauseAll(); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-export.json"; panel.allowedContentTypes = [.json]; if panel.runModal() == .OK,libraryWorkAvailable,let url = panel.url { do { try store.exportJSON(to:url) } catch { errorMessage = error.localizedDescription } } }
    func importData(limitlessAPI:Bool=false) {
        guard libraryWorkAvailable,!importingJSON else {return};let panel=NSOpenPanel();panel.allowedContentTypes=[.json]
        if limitlessAPI {panel.title="Import Limitless API JSON";panel.message="Choose a saved API response containing data.lifelogs or data.lifelog. Account-export ZIP files, audio and Rewind databases are not supported."}
        if panel.runModal() == .OK,let url=panel.url {importJSONFile(url,limitlessAPI:limitlessAPI)}
    }
    func cancelJSONImport() {jsonImportWorker?.cancel();jsonImportTask?.cancel()}
    /// Join both the actual worker and its UI completion, even if the drain
    /// caller is cancelled. No acknowledgement precedes descriptor release.
    func cancelJSONImportAndWait() async {
        jsonImportDrainers+=1;defer {jsonImportDrainers-=1}
        let worker=jsonImportWorker,completion=jsonImportTask
        worker?.cancel();completion?.cancel()
        if let worker {_ = try? await worker.value}
        if let completion {await completion.value}
    }
    enum JSONImportPhase:Sendable {case started,settingsCaptured}
    // The observer is an internal test seam; production callers leave it nil.
    func importJSONFile(_ url:URL,limitlessAPI:Bool=false,observeWorker:(@Sendable (JSONImportPhase)throws->Void)?=nil,scannerFactory:@escaping @Sendable (PIIImportConfiguration) async throws->PIIImportScanner = {try await $0.scanner()}) {
        guard libraryWorkAvailable,!libraryWipe.busy,!importingJSON,jsonImportDrainers==0 else {return};importingJSON=true;importStatus=limitlessAPI ? "Importing Limitless text and checking privacy rules…":"Importing sources and checking recap links…"
        let store=self.store,embedder=self.embedder,policy=settings.privacy,pii=settings.piiImports,generation=libraryOperationGeneration
        let worker=Task.detached(priority:.utility) {()throws->String in
            try Task.checkCancellation();try observeWorker?(.started);try Task.checkCancellation()
            let activity=try store.mediaWriteLease();defer {activity.release()}
            let snapshot=try LibrarySettingsSnapshot.capture(root:store.root)
            defer {snapshot.release()}
            guard snapshot.settings.privacy==policy,snapshot.settings.piiImports==pii else {throw OSwindError.unavailable("The import's privacy settings no longer match saved settings. Retry with the current privacy settings.")}
            try observeWorker?(.settingsCaptured);try Task.checkCancellation()
            func perform(_ scanner:PIIImportScanner?) async throws -> String {
                func suffix(_ result:PIIImportSummary?)->String {
                    guard let result else {return ""}
                    return " Additional experimental PII masking: \(result.redactedSources) of \(result.sources) sources changed (\(result.compute.rawValue), threshold \(result.threshold)); detection is incomplete."
                }
                if limitlessAPI {
                    let result:LimitlessImportResult
                    if let scanner {result=try await store.importLimitlessAPI(from:url,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity,scanner:scanner)}
                    else {result=try store.importLimitlessAPI(from:url,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity)}
                    return "Imported \(result.imported) Limitless text notes · \(result.excluded) excluded."+(result.hasMorePages ? " This response has another page; import each saved page to complete the export.":" Only the supplied response was imported.")+suffix(result.learnedPrivacy)
                }
                let result:JSONImportResult
                if let scanner {result=try await store.importJSONDetailed(from:url,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity,scanner:scanner)}
                else {result=try store.importJSONDetailed(from:url,embedder:embedder,policy:policy,settingsSnapshot:snapshot,admission:activity)}
                return "Imported \(result.imported) records · \(result.excluded) excluded · \(result.skippedLinkedRecaps) linked recaps omitted because an original was excluded, redacted or stale."+suffix(result.learnedPrivacy)
            }
            if pii.enabled {
                let scanner=try await scannerFactory(pii)
                do {let result=try await perform(scanner);await scanner.shutdown();return result}
                catch {await scanner.shutdown();throw error}
            }
            return try await perform(nil)
        }
        jsonImportWorker=worker
        jsonImportTask=Task {
            defer {importingJSON=false;jsonImportTask=nil;jsonImportWorker=nil}
            do {
                let status=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
                guard libraryOperationGeneration==generation else {return}
                importStatus=status
                selected=nil;invalidateStorageEstimate();refresh(forceStatistics:true);refreshChats();await catchUpIndex()
            } catch is CancellationError {guard libraryOperationGeneration==generation else {return};importStatus="Import cancelled before publication."}
            catch {guard libraryOperationGeneration==generation else {return};importStatus="Import did not complete: "+error.localizedDescription;errorMessage=error.localizedDescription}
        }
    }

    func startAPI() {
        guard libraryWorkAvailable,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup else {return}
        if api != nil {settings.apiEnabled=true;return}
        do {
            api=try LocalAPIServer(store:store,embedder:embedder)
            apiGeneration=UUID();let generation=apiGeneration
            api?.onState = { [weak self] text in Task { @MainActor in guard let self,self.apiGeneration==generation,self.api != nil else {return};self.apiStatus=text } }
            try api?.start();settings.apiEnabled=true
        } catch {stopAPI(preservePreference:true);apiStatus=error.localizedDescription}
    }
    func stopAPI(preservePreference:Bool=false) {
        // Already queued callbacks keep their old ticket and cannot relabel a
        // stopped or replacement listener. Do not mutate its callback on stop.
        apiGeneration=UUID();api?.stop();api=nil;apiStatus="API off"
        if !preservePreference {settings.apiEnabled=false}
    }
    func login(_ enabled: Bool) { do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { errorMessage = error.localizedDescription } }
    func seedDemo() throws {
        guard try store.stats().count == 0 else { return }
        let examples: [(String,String,String,MemoryKind)] = [
            ("Safari","Designing a quieter desktop","Research notes: event-driven capture reduces duplicate frames. Keep a clear pause control and searchable evidence. The interface should feel calm and immediate.",.screen),
            ("Xcode","OSwind / CaptureEngine.swift","Implementation decision: use ScreenCaptureKit for capture, Apple Vision for OCR, SQLite FTS5 for lexical retrieval, and local sentence embeddings for semantic recall.",.screen),
            ("System audio","Product sync · sample transcript","Alex: Let's ship the local-first experience first. Sam: I will own the retrieval benchmark by Friday. Decision: default to Balanced mode and keep cloud providers opt-in.",.audio),
            ("Notes","A small idea worth keeping","A memory tool should help you get back to the work, with the original source one click away. Never hide an evidence gap behind a confident answer.",.note),
            ("Safari","Apple Vision documentation","Vision recognizes text on device. Benchmark OCR fidelity with screenshots containing small text, dark backgrounds, multiple languages and different display scales.",.screen),
            ("OSwind","Today’s sample recap","Built a capture prototype and discussed retrieval quality. Next: verify privacy boundaries and measure idle energy. This is sample data, not your recorded activity.",.summary)
        ]
        for (i,item) in examples.enumerated() { var m = Memory(timestamp:Date().addingTimeInterval(-Double(i*1100)),kind:item.3,app:item.0,title:item.1,text:item.2,favorite:i == 3,tags:["sample"]); m.embedding = embedder.embed(m.searchableText); m.embeddingModel = embedder.modelID; try store.insert(m) }
    }
}
