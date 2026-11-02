import Foundation
import OSwindCore

extension AppModel {
    var visualPowerAllowed:Bool {
        (settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)
    }
    func resumeAutomaticVisualIndex() {
        guard libraryWorkAvailable,visualAutoResumeAllowed,!showOnboarding,!demo,!SessionState.locked,!libraryWipe.busy,!libraryWipe.pendingCleanup,!libraryTransfer.busy,settings.search.visual.enabled,settings.search.visual.automaticIndex,visualPowerAllowed,!visualIndexing else {return}
        rebuildVisualIndex(pendingOnly:true)
    }
    func cancelVisualIndexing() {
        visualGeneration=UUID();visualIndexTask?.cancel();visualAutomaticTask?.cancel();visualIndexTask=nil;visualAutomaticTask=nil
        libraryWork.cancel(kinds:[.visualRebuild,.automaticVisual]);pendingVisualIDs.removeAll()
        visualIndexing=libraryWork.count(kinds:[.visualRebuild])>0;visualAutomaticIndexing=libraryWork.count(kinds:[.automaticVisual])>0
        visualIndexStatus=visualIndexing || visualAutomaticIndexing ? "Stopping local visual work…":"Visual indexing stopped."
    }
    func queueVisualIndex(_ memory:Memory) {
        guard libraryWorkAvailable,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup,settings.search.visual.enabled,settings.search.visual.automaticIndex,memory.kind == .screen,memory.imagePath != nil || memory.videoPath != nil else {return}
        visualAutoResumeAllowed=true
        guard !settings.search.visual.modelDirectory.isEmpty else {visualIndexStatus="Choose a prepared local visual model in Models settings.";return}
        guard visualPowerAllowed else {visualIndexStatus="Visual indexing paused by power or thermal policy. Build / resume later to catch up.";return}
        guard pendingVisualIDs.count<64 else {visualIndexStatus="Visual indexing is behind capture. Build / resume to catch up.";return}
        pendingVisualIDs.removeAll {$0==memory.id};pendingVisualIDs.append(memory.id);startAutomaticVisualIndex()
    }
    private func finishVisualIndex(_ outcome:Result<String,Error>,generation:UUID,cancelled:Bool,automatic:Bool) {
        visualIndexing=libraryWork.count(kinds:[.visualRebuild])>(automatic ? 0:1)
        visualAutomaticIndexing=libraryWork.count(kinds:[.automaticVisual])>(automatic ? 1:0)
        if !visualIndexing {visualIndexTask=nil};if !visualAutomaticIndexing {visualAutomaticTask=nil}
        defer {Task {@MainActor [weak self] in self?.startAutomaticVisualIndex()}}
        let invalidated=visualGeneration != generation || cancelled
        if libraryStatusAvailable,invalidated,!visualIndexing,!visualAutomaticIndexing,visualIndexStatus.hasPrefix("Stopping") {visualIndexStatus="Visual indexing stopped."}
        guard libraryWorkAvailable,!invalidated else {return}
        switch outcome {
        case .success(let message):visualIndexStatus=message;if !automatic {visualIndexProgress=1};if mode == .visual {refresh()}
        case .failure(is CancellationError):visualIndexStatus="Visual indexing stopped."
        case .failure(let error):visualIndexStatus=error.localizedDescription;if automatic {pendingVisualIDs.removeAll()}
        }
    }
    func startAutomaticVisualIndex() {
        guard libraryWorkAvailable,visualAutoResumeAllowed,!showOnboarding,!libraryWipe.busy,!libraryWipe.pendingCleanup,visualAutomaticTask==nil,!visualAutomaticIndexing,!visualIndexing,libraryWork.count(kinds:[.automaticVisual])==0,settings.search.visual.enabled,settings.search.visual.automaticIndex,visualPowerAllowed,!pendingVisualIDs.isEmpty else {return}
        let ids=Array(pendingVisualIDs.prefix(8));pendingVisualIDs.removeFirst(ids.count)
        let generation=visualGeneration,configuration=settings.search.visual,policy=settings.privacy,allowLowPower=settings.search.indexOnLowPower,store=self.store,observe=searchWorkObserver,completed=searchWorkCompleted,registry=libraryWork
        visualAutomaticIndexing=true;visualIndexStatus="Indexing latest retained visuals…"
        guard let id=registry.launch(kind:.automaticVisual,operation:{
            defer {completed?(.automaticVisual)}
            try Task.checkCancellation();try await observe?(.automaticVisual);try Task.checkCancellation()
            let memories=try ids.compactMap {try store.get($0)}
            let result=try await VisualRetrievalEngine(store:store).index(memories,configuration:configuration,policy:policy,shouldContinue:{(allowLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)})
            return result.failedSources==0 ? "Indexed \(result.indexedFrames) visual frames from the latest captures.":"Visual indexing needs attention: \(result.errors.first ?? "some sources could not be indexed")"
        },completion:{[weak self] outcome,cancelled in self?.finishVisualIndex(outcome,generation:generation,cancelled:cancelled,automatic:true)}) else {visualAutomaticIndexing=false;return}
        visualAutomaticTask=Task {await registry.wait(for:id)}
    }
    func rebuildVisualIndex(pendingOnly:Bool=false) {
        guard libraryWorkAvailable,!libraryWipe.busy,!libraryWipe.pendingCleanup,!visualIndexing,libraryWork.count(kinds:[.visualRebuild])==0 else {return}
        guard visualPowerAllowed else {visualIndexStatus="Disable Low Power Mode or allow background indexing, and wait for thermal pressure to ease.";return}
        cancelVisualIndexing()
        let generation=visualGeneration,configuration=settings.search.visual,policy=settings.privacy,allowLowPower=settings.search.indexOnLowPower,store=self.store,observe=searchWorkObserver,completed=searchWorkCompleted,registry=libraryWork
        visualIndexing=true;visualIndexProgress=0;visualIndexStatus="Preparing local visual models…"
        guard let id=registry.launch(kind:.visualRebuild,operation:{[weak self] in
            defer {completed?(.visualRebuild)}
            try Task.checkCancellation();try await observe?(.visualRebuild);try Task.checkCancellation()
            let result=try await VisualRetrievalEngine(store:store).rebuild(configuration:configuration,policy:policy,pendingOnly:pendingOnly,shouldContinue:{(allowLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)}) {progress in
                Task {@MainActor [weak self] in guard let self,self.libraryWorkAvailable,self.visualGeneration==generation,self.visualIndexing else {return};self.visualIndexProgress=progress.totalSources>0 ? min(1,Double(progress.processedSources)/Double(progress.totalSources)):0;self.visualIndexStatus="\(progress.processedSources) / \(progress.totalSources) sources checked · \(progress.indexedFrames) visual frames indexed"}
            }
            try Task.checkCancellation();let coverage=try store.visualCoverage(modelID:result.modelID)
            var message="Visual index: \(coverage.indexedSources) / \(coverage.sources) sources, \(coverage.indexedFrames) frames. \(result.skippedSources) skipped · \(result.failedSources) failed."
            if let error=result.errors.first {message+=" "+error};return message
        },completion:{[weak self] outcome,cancelled in self?.finishVisualIndex(outcome,generation:generation,cancelled:cancelled,automatic:false)}) else {visualIndexing=false;return}
        visualIndexTask=Task {await registry.wait(for:id)}
    }
}
