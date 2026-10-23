import SwiftUI
import AVFoundation
import OSwindCore

@MainActor final class AudioPlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing=false
    @Published var position=0.0
    @Published var duration=0.0
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var sourceURL: URL?
    func load(_ url: URL) {
        stop(); duration=0; position=0; error=nil; sourceURL=nil
        do { let player=try AVAudioPlayer(contentsOf:url); guard player.duration.isFinite,player.duration>0 else { throw OSwindError.invalid("Invalid audio duration") }; sourceURL=url; player.delegate=self; player.prepareToPlay(); self.player=player; duration=player.duration; position=0; error=nil }
        catch { self.error=error.localizedDescription }
    }
    func toggle() {
        guard let player else { return }
        guard let sourceURL,FileManager.default.fileExists(atPath:sourceURL.path) else { stop(); error="This recording is no longer available"; return }
        if playing { player.pause(); playing=false; timer?.invalidate(); timer=nil }
        else { if player.currentTime>=player.duration { player.currentTime=0 }; playing=player.play(); if !playing { error="Audio output could not start" }; if playing { timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in Task { @MainActor in guard let self,let player=self.player else { return }; if let url=self.sourceURL,!FileManager.default.fileExists(atPath:url.path) { self.stop(); self.error="This recording is no longer available"; return }; self.position=player.currentTime } } } }
    }
    func seek(_ seconds: Double) { guard seconds.isFinite,let player else { return }; player.currentTime=max(0,min(seconds,player.duration)); position=player.currentTime }
    func stop() { timer?.invalidate(); timer=nil; player?.stop(); player=nil; playing=false }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self,weak player] in guard let self,let player,self.player === player else { return }; self.playing=false; self.position=self.duration; self.timer?.invalidate(); self.timer=nil; if !flag { self.error="Audio playback did not finish successfully" } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message=error?.localizedDescription ?? "Audio decoding failed"
        Task { @MainActor [weak self,weak player] in guard let self,let player,self.player === player else { return }; self.stop(); self.error=message }
    }
    deinit { timer?.invalidate(); player?.stop() }
}
struct AudioPlaybackView: View {
    let memory: Memory
    let url: URL?
    @StateObject private var playback=AudioPlaybackModel()
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let url {
                HStack {
                    Button { playback.toggle() } label: { Image(systemName:playback.playing ? "pause.fill":"play.fill").frame(width:18) }.accessibilityLabel(playback.playing ? "Pause clip":"Play clip").disabled(playback.error != nil)
                    Slider(value:Binding(get:{playback.position},set:{playback.seek($0)}),in:0...max(0.01,playback.duration)).accessibilityLabel("Clip position")
                    Text(time(playback.position)+" / "+time(playback.duration)).font(.system(.caption,design:.monospaced)).monospacedDigit()
                }.onAppear { playback.load(url) }.onChange(of:url) { _,value in playback.load(value) }
            } else { Label("Audio was not retained for this transcript",systemImage:"waveform.slash").font(.caption).foregroundStyle(.secondary) }
            if let error=playback.error { HStack { Text(error).font(.caption).foregroundStyle(.orange); if let url { Button("Retry") { playback.load(url) } } } }
            if let transcript=memory.transcript {
                Text(transcript.model+" · "+time(transcript.duration)).font(.caption2).foregroundStyle(.secondary)
                LazyVStack(alignment:.leading,spacing:0) { ForEach(Array(transcript.segments.enumerated()),id:\.offset) { _, segment in
                    HStack(alignment:.top,spacing:12) {
                        Button(time(segment.start)) { playback.seek(segment.start) }.font(.system(.caption,design:.monospaced)).buttonStyle(.borderless).disabled(url == nil)
                        VStack(alignment:.leading,spacing:3) { if let speaker=segment.speaker { Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(OSwindTheme.accent) }; Text(segment.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                    }.padding(.vertical,4)
                } }
            }
        }.padding(14).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).onDisappear { playback.stop() }
    }
    private func time(_ value: Double) -> String { let seconds=Int(max(0,value.isFinite ? value:0)); return seconds>=3600 ? String(format:"%d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60) : String(format:"%d:%02d",seconds/60,seconds%60) }
}
