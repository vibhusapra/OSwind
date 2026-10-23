import SwiftUI
import AVKit
import OSwindCore

@MainActor final class VideoReplayModel:ObservableObject {
    @Published private(set) var player:AVPlayer?
    @Published private(set) var position=0.0
    @Published private(set) var duration=0.0
    @Published private(set) var playing=false
    @Published private(set) var error:String?
    private var observer:Any?
    private var endObserver:NSObjectProtocol?
    private var ownedPlayer:AVPlayer?
    private var generation=UUID()
    private var sourceURL:URL?
    func load(_ url:URL,seek:Double=0) async {
        stop();let token=generation
        do {
            guard FileManager.default.fileExists(atPath:url.path) else {throw OSwindError.unavailable("This replay clip is no longer available")}
            let asset=AVURLAsset(url:url),duration=try await asset.load(.duration).seconds
            let playable=try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard generation==token else {return}
            guard playable,duration.isFinite,duration>0,duration<=120.01 else {throw OSwindError.invalid("Invalid replay video")}
            let player=AVPlayer(playerItem:AVPlayerItem(asset:asset));player.isMuted=true
            self.player=player;ownedPlayer=player;self.duration=duration;sourceURL=url;error=nil
            observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self,weak player] time in
                Task {@MainActor in
                    guard let self,let player,self.generation==token else {return}
                    guard FileManager.default.fileExists(atPath:url.path) else {self.stop();self.error="This replay clip is no longer available";return}
                    if time.seconds.isFinite {self.position=max(0,min(time.seconds,self.duration))}
                    self.playing=player.rate>0
                    if let failure=player.currentItem?.error {self.error=failure.localizedDescription;player.pause();self.playing=false}
                }
            }
            endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:player.currentItem,queue:.main) { [weak self] _ in
                Task {@MainActor in guard let self,self.generation==token else {return};self.playing=false;self.position=self.duration}
            }
            self.seek(seek)
        } catch is CancellationError {} catch {if generation==token {self.error=error.localizedDescription}}
    }
    func toggle() {
        guard let player,let sourceURL,FileManager.default.fileExists(atPath:sourceURL.path) else {stop();error="This replay clip is no longer available";return}
        if playing {player.pause();playing=false} else {if position>=duration-0.01 {seek(0)};player.play();playing=true}
    }
    func seek(_ seconds:Double) {
        guard seconds.isFinite,let player else {return}
        let value=max(0,min(seconds,max(0,duration-1.0/600)))
        position=value;player.seek(to:CMTime(seconds:value,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
    }
    func stop() {
        generation=UUID();player?.pause();if let observer {player?.removeTimeObserver(observer)};observer=nil;if let endObserver {NotificationCenter.default.removeObserver(endObserver)};endObserver=nil;player=nil;ownedPlayer=nil;playing=false;duration=0;position=0;sourceURL=nil;error=nil
    }
    deinit {if let endObserver {NotificationCenter.default.removeObserver(endObserver)};ownedPlayer?.pause();if let observer {ownedPlayer?.removeTimeObserver(observer)}}
}
/// Vision regions use bottom-left normalized coordinates; AVPlayerView letterboxes
/// within the SwiftUI surface. Map boxes into the actual video rect, not the view.
enum ReplayVideoGeometry {
    static func regionRect(_ region:TextRegion,video:CGSize,container:CGSize)->CGRect {
        let fitted=AVMakeRect(aspectRatio:video,insideRect:CGRect(origin:.zero,size:container))
        return CGRect(x:fitted.minX+fitted.width*region.x,
                      y:fitted.minY+fitted.height*(1-region.y-region.height),
                      width:fitted.width*region.width,height:fitted.height*region.height)
    }
}
private struct ReplayPlayerSurface:NSViewRepresentable {
    let player:AVPlayer?
    func makeNSView(context:Context)->AVPlayerView {let view=AVPlayerView();view.controlsStyle = .none;view.videoGravity = .resizeAspect;view.player=player;return view}
    func updateNSView(_ view:AVPlayerView,context:Context) {view.player=player}
}
struct VideoReplayView:View {
    let recording:VisualRecording
    let url:URL?
    let initialTime:Double
    @Binding var boxes:Bool
    @StateObject private var playback=VideoReplayModel()
    private var activeIndex:Int {recording.frames.lastIndex(where:{$0.time<=playback.position+0.001}) ?? 0}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if let url {
                ReplayPlayerSurface(player:playback.player)
                    .aspectRatio(CGFloat(recording.width)/CGFloat(recording.height),contentMode:.fit)
                    .frame(maxHeight:350)
                    .overlay {if boxes {GeometryReader {geometry in ForEach(Array(recording.frames[activeIndex].regions.enumerated()),id:\.offset) {_,region in
                        let rect=ReplayVideoGeometry.regionRect(region,video:CGSize(width:recording.width,height:recording.height),container:geometry.size)
                        Rectangle().stroke(OSwindTheme.accent,lineWidth:1).frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY)
                    }}.allowsHitTesting(false)}}
                    .clipShape(RoundedRectangle(cornerRadius:9))
                HStack {
                    Button {playback.toggle()} label:{Image(systemName:playback.playing ? "pause.fill":"play.fill").frame(width:18)}.accessibilityLabel(playback.playing ? "Pause replay":"Play replay").disabled(playback.player==nil || playback.error != nil)
                    Slider(value:Binding(get:{playback.position},set:{playback.seek($0)}),in:0...max(0.01,playback.duration)).accessibilityLabel("Replay position").disabled(playback.player==nil)
                    Text(time(playback.position)+" / "+time(playback.duration)).font(.system(.caption,design:.monospaced)).monospacedDigit()
                }.task(id:url) {await playback.load(url,seek:initialTime)}
            } else {Label("Video was not retained; timed source text is available",systemImage:"film").font(.caption).foregroundStyle(.secondary)}
            if let error=playback.error {Text(error).font(.caption).foregroundStyle(.orange)}
            Text("\(recording.frames.count) sampled frames · \(recording.width) × \(recording.height) · \(recording.codec.uppercased())").font(.caption).foregroundStyle(.secondary)
            Text("Select a frame time to seek. Gaps and unchanged frames are omitted; this clip does not prove uninterrupted coverage.").font(.caption2).foregroundStyle(.secondary)
            LazyVStack(alignment:.leading,spacing:8) {ForEach(Array(recording.frames.enumerated()),id:\.offset) {index,frame in
                HStack(alignment:.top,spacing:12) {
                    Button(time(frame.time)) {playback.seek(frame.time)}.font(.system(.caption,design:.monospaced)).buttonStyle(.borderless).disabled(url==nil || playback.player==nil)
                    Text(frame.text.isEmpty ? "No extracted text":frame.text).textSelection(.enabled).font(.callout).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(10).background(index==activeIndex && url != nil ? OSwindTheme.accent.opacity(0.08):.clear,in:RoundedRectangle(cornerRadius:6))
            }}
        }.onDisappear {playback.stop()}
    }
    private func time(_ seconds:Double)->String {String(format:"%02d:%04.1f",Int(max(0,seconds))/60,max(0,seconds).truncatingRemainder(dividingBy:60))}
}
