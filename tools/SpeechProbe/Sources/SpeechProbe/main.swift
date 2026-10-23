import Foundation
import CoreML
import FluidAudio

@main struct SpeechProbe {
    static func main() async throws {
        let arguments=Array(CommandLine.arguments.dropFirst())
        guard arguments.count==3 else { throw NSError(domain:"SpeechProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Use AUDIO CACHE_DIRECTORY REPORT_JSON"]) }
        AppLogger.minimumLevel = .warning
        let manager=OfflineDiarizerManager(), configuration=MLModelConfiguration(); configuration.computeUnits = .all
        let start=Date()
        let models=try await OfflineDiarizerModels.load(from:URL(fileURLWithPath:arguments[1]),configuration:configuration)
        manager.initialize(models:models)
        let loaded=Date(), result=try await manager.process(URL(fileURLWithPath:arguments[0]))
        let segments=result.segments.map { ["speaker":$0.speakerId,"start":$0.startTimeSeconds,"end":$0.endTimeSeconds] as [String:Any] }
        let object:[String:Any] = ["sdk":"FluidAudio v0.17.7 / 503b4bd1","scope":"isolated component; synthetic speaker consistency, not product integration or natural-meeting DER","load_seconds":loaded.timeIntervalSince(start),"processing_seconds":Date().timeIntervalSince(loaded),"segments":segments]
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:arguments[2]))
        print("Wrote",segments.count,"diarization segments")
    }
}
