import SwiftUI
import AVFoundation
import OSwindCore

@MainActor final class AudioPlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing=false
    @Published var position=0.0
    @Published var duration=0.0
    @Published var volume: Float=1 { didSet { player?.volume=max(0,min(volume,1)) } }
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var sourceURL: URL?
    func load(_ url: URL) {
        stop(); duration=0; position=0; error=nil; sourceURL=nil
        do { let player=try AVAudioPlayer(contentsOf:url); guard player.duration.isFinite,player.duration>0 else { throw OSwindError.invalid("Invalid audio duration") }; sourceURL=url; player.volume=max(0,min(volume,1)); player.delegate=self; player.prepareToPlay(); self.player=player; duration=player.duration; position=0; error=nil }
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
    @EnvironmentObject private var model:AppModel
    @StateObject private var playback=AudioPlaybackModel()
    @State private var editedTranscript:SpeechTranscript?
    @State private var paragraphs=[TranscriptParagraph]()
    @State private var renaming=false
    @State private var renameOriginal=""
    @State private var speakerName=""
    @State private var renameError:String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let url {
                HStack {
                    Button { playback.toggle() } label: { Image(systemName:playback.playing ? "pause.fill":"play.fill").frame(width:18) }.accessibilityLabel(playback.playing ? "Pause clip":"Play clip").disabled(playback.error != nil)
                    Slider(value:Binding(get:{playback.position},set:{playback.seek($0)}),in:0...max(0.01,playback.duration)).accessibilityLabel("Clip position")
                    Text(time(playback.position)+" / "+time(playback.duration)).font(.system(.caption,design:.monospaced)).monospacedDigit()
                }.onAppear { playback.load(url) }.onChange(of:url) { _,value in playback.load(value) }
                HStack { Image(systemName:playback.volume==0 ? "speaker.slash":"speaker.wave.2"); Slider(value:$playback.volume,in:0...1).frame(maxWidth:140).accessibilityLabel("Playback volume") }.font(.caption).foregroundStyle(.secondary)
            } else { Label("Audio was not retained for this transcript",systemImage:"waveform.slash").font(.caption).foregroundStyle(.secondary) }
            if let error=playback.error { HStack { Text(error).font(.caption).foregroundStyle(.orange); if let url { Button("Retry") { playback.load(url) } } } }
            if let error=renameError { Text(error).font(.caption).foregroundStyle(.orange) }
            if let transcript=editedTranscript ?? memory.transcript {
                Text(transcript.model+" · "+time(transcript.duration)).font(.caption2).foregroundStyle(.secondary)
                if let info=transcript.diarization {
                    Text("\(info.detectedSpeakers) estimated speakers · \(transcript.segments.count-info.unassignedSegments)/\(transcript.segments.count) timed spans assigned").font(.caption).foregroundStyle(.secondary)
                    Text("Labels apply to this recording only. Select a speaker label to name it.").font(.caption2).foregroundStyle(.secondary)
                }
                LazyVStack(alignment:.leading,spacing:12) { ForEach(paragraphs) { paragraph in
                    HStack(alignment:.top,spacing:12) {
                        Button(time(paragraph.start)) { playback.seek(paragraph.start) }.font(.system(.caption,design:.monospaced)).buttonStyle(.borderless).disabled(url == nil || playback.error != nil)
                        VStack(alignment:.leading,spacing:4) {
                            if let speaker=paragraph.speaker {
                                Button(speaker) { renameOriginal=speaker; speakerName=speaker; renameError=nil; renaming=true }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(OSwindTheme.accent).help("Name this speaker for this recording")
                            } else if transcript.diarization != nil { Text("Unassigned or mixed").font(.caption2).foregroundStyle(.secondary) }
                            Text(words(paragraph,in:transcript)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).help(url == nil ? "Transcript":"Select a word to seek")
                        }
                    }
                } }.environment(\.openURL,OpenURLAction { target in
                    guard target.scheme=="oswind-audio-seek",target.host=="seek",let components=URLComponents(url:target,resolvingAgainstBaseURL:false),let raw=components.queryItems?.first(where:{$0.name=="segment"})?.value,let index=Int(raw),transcript.segments.indices.contains(index),url != nil else { return .discarded }
                    playback.seek(transcript.segments[index].start); return .handled
                })
            }
        }.alert("Name this speaker",isPresented:$renaming) {
            TextField("Speaker name",text:$speakerName)
            Button("Save") {
                do { editedTranscript=try model.store.renameAudioSpeaker(memory.id,from:renameOriginal,to:speakerName,policy:model.settings.privacy).transcript; rebuildParagraphs(); model.refresh() }
                catch { renameError=error.localizedDescription }
            }
            Button("Cancel",role:.cancel) {}
        } message: { Text("Changes labels in this recording only. No voice profile is created.") }
        .onAppear { rebuildParagraphs() }
        .onChange(of:memory.id) { _,_ in editedTranscript=nil; renameError=nil; rebuildParagraphs() }
        .onChange(of:memory.transcript) { _,_ in editedTranscript=nil; rebuildParagraphs() }
        .padding(14).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).onDisappear { playback.stop() }
    }
    private func rebuildParagraphs() {
        guard let transcript=editedTranscript ?? memory.transcript else { paragraphs=[]; return }
        paragraphs=(try? TranscriptParagraph.make(transcript)) ?? []
    }
    private func words(_ paragraph:TranscriptParagraph,in transcript:SpeechTranscript) -> AttributedString {
        var text=AttributedString()
        for index in paragraph.range where transcript.segments.indices.contains(index) {
            let segment=transcript.segments[index]
            if index>paragraph.range.lowerBound { text.append(AttributedString(" ")) }
            var word=AttributedString(segment.text); word.foregroundColor = .primary
            if url != nil && playback.error==nil { word.link=URL(string:"oswind-audio-seek://seek?segment=\(index)") }
            if url != nil && playback.position>=segment.start && playback.position<segment.end { word.backgroundColor=OSwindTheme.accent.opacity(0.18) }
            text.append(word)
        }
        return text
    }
    private func time(_ value: Double) -> String { let seconds=Int(max(0,value.isFinite ? value:0)); return seconds>=3600 ? String(format:"%d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60) : String(format:"%d:%02d",seconds/60,seconds%60) }
}
