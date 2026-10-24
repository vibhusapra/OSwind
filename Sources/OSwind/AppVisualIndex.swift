import Foundation
import OSwindCore

extension AppModel {
    var visualPowerAllowed:Bool {
        (settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)
    }
    func resumeAutomaticVisualIndex() {
        guard visualAutoResumeAllowed,!demo,!store.isClosed,!SessionState.locked,!libraryWipe.busy,!libraryTransfer.busy,settings.search.visual.enabled,settings.search.visual.automaticIndex,visualPowerAllowed,!visualIndexing else {return}
        rebuildVisualIndex(pendingOnly:true)
    }
    func cancelVisualIndexing() {
        visualGeneration=UUID();visualIndexTask?.cancel();visualAutomaticTask?.cancel();visualIndexTask=nil;visualAutomaticTask=nil;pendingVisualIDs.removeAll();visualIndexing=false;visualAutomaticIndexing=false;visualIndexStatus="Visual indexing cancelled; completed sources remain."
    }
    func queueVisualIndex(_ memory:Memory) {
        guard settings.search.visual.enabled,settings.search.visual.automaticIndex,memory.kind == .screen,memory.imagePath != nil || memory.videoPath != nil else {return}
        visualAutoResumeAllowed=true
        guard !settings.search.visual.modelDirectory.isEmpty else {visualIndexStatus="Choose a prepared local visual model in Models settings.";return}
        guard visualPowerAllowed else {visualIndexStatus="Visual indexing paused by power or thermal policy. Build / resume later to catch up.";return}
        guard pendingVisualIDs.count<64 else {visualIndexStatus="Visual indexing is behind capture. Build / resume to catch up.";return}
        pendingVisualIDs.removeAll {$0==memory.id};pendingVisualIDs.append(memory.id);startAutomaticVisualIndex()
    }
    func startAutomaticVisualIndex() {
        guard visualAutomaticTask==nil,!visualIndexing,settings.search.visual.enabled,settings.search.visual.automaticIndex,visualPowerAllowed,!pendingVisualIDs.isEmpty else {return}
        let generation=visualGeneration;visualAutomaticIndexing=true;visualIndexStatus="Indexing latest retained visuals…"
        visualAutomaticTask=Task { [weak self] in
            guard let self else {return}
            defer {if visualGeneration==generation {visualAutomaticTask=nil;visualAutomaticIndexing=false}}
            while !pendingVisualIDs.isEmpty,!Task.isCancelled,visualGeneration==generation,visualPowerAllowed {
                let ids=Array(pendingVisualIDs.prefix(8));pendingVisualIDs.removeFirst(ids.count)
                let configuration=settings.search.visual,policy=settings.privacy,allowLowPower=settings.search.indexOnLowPower
                do {
                    let memories=try ids.compactMap {try store.get($0)}
                    let result=try await VisualRetrievalEngine(store:store).index(memories,configuration:configuration,policy:policy,shouldContinue:{(allowLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)})
                    guard visualGeneration==generation,!Task.isCancelled else {return}
                    visualIndexStatus=result.failedSources==0 ? "Indexed \(result.indexedFrames) visual frames from the latest captures.":"Visual indexing needs attention: \(result.errors.first ?? "some sources could not be indexed")"
                    if mode == .visual {refresh()}
                } catch is CancellationError {return}
                catch {guard visualGeneration==generation else {return};visualIndexStatus=error.localizedDescription;pendingVisualIDs.removeAll();return}
            }
        }
    }
    func rebuildVisualIndex(pendingOnly:Bool=false) {
        guard !visualIndexing else {return}
        guard visualPowerAllowed else {visualIndexStatus="Disable Low Power Mode or allow background indexing, and wait for thermal pressure to ease.";return}
        cancelVisualIndexing();let generation=visualGeneration,configuration=settings.search.visual,policy=settings.privacy,allowLowPower=settings.search.indexOnLowPower
        visualIndexing=true;visualIndexProgress=0;visualIndexStatus="Preparing local visual models…"
        visualIndexTask=Task { [weak self] in
            guard let self else {return}
            defer {if visualGeneration==generation {visualIndexing=false;visualIndexTask=nil;startAutomaticVisualIndex()}}
            do {
                let result=try await VisualRetrievalEngine(store:store).rebuild(configuration:configuration,policy:policy,pendingOnly:pendingOnly,shouldContinue:{(allowLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled) && ![.serious,.critical].contains(ProcessInfo.processInfo.thermalState)}) {progress in
                    Task {@MainActor [weak self] in guard let self,self.visualGeneration==generation,self.visualIndexing else {return};self.visualIndexProgress=progress.totalSources>0 ? min(1,Double(progress.processedSources)/Double(progress.totalSources)):0;self.visualIndexStatus="\(progress.processedSources) / \(progress.totalSources) sources checked · \(progress.indexedFrames) visual frames indexed"}
                }
                guard visualGeneration==generation,!Task.isCancelled else {return}
                let coverage=try store.visualCoverage(modelID:result.modelID)
                visualIndexProgress=1;visualIndexStatus="Visual index: \(coverage.indexedSources) / \(coverage.sources) sources, \(coverage.indexedFrames) frames. \(result.skippedSources) skipped · \(result.failedSources) failed."
                if let error=result.errors.first {visualIndexStatus += " "+error}
                if mode == .visual {refresh()}
            } catch is CancellationError {guard visualGeneration==generation else {return};visualIndexStatus="Visual indexing cancelled; completed sources are saved."}
            catch {guard visualGeneration==generation else {return};visualIndexStatus=error.localizedDescription}
        }
    }
}
