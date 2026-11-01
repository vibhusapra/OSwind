#if DEBUG
import Foundation
import OSwindCore

/// Authored component states only. No microphone, AX, pasteboard, or inference.
@MainActor final class VoicePreviewRecorder:DictationRecording {
    var full:Bool {false}
    func start()async throws {throw OSwindError.unavailable("Sample preview never records")}
    func finish()throws->[Float] {throw CancellationError()}
    func cancel() {}
}
#endif
