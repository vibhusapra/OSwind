import AppKit
import AVFoundation

// Owned physical-audio source. It starts silent, plays only while its explicit
// control marker exists, never requests capture access and never changes volume.
let arguments=CommandLine.arguments
guard arguments.count==4 else {exit(64)}
let wav=URL(fileURLWithPath:arguments[1]),control=URL(fileURLWithPath:arguments[2])
let application=NSApplication.shared;application.setActivationPolicy(.regular)
let player=try AVAudioPlayer(contentsOf:wav);player.volume=0.2;player.numberOfLoops = -1;player.prepareToPlay()
let window=NSWindow(contentRect:NSRect(x:140,y:160,width:420,height:140),styleMask:[.titled],backing:.buffered,defer:false)
window.title="OSwind owned audio fixture"
let label=NSTextField(wrappingLabelWithString:"Generated tone only.\nNo microphone, user audio or library access.")
label.frame=NSRect(x:20,y:20,width:380,height:100);window.contentView?.addSubview(label);window.orderFront(nil);window.orderOut(nil)
let ready=URL(fileURLWithPath:arguments[3])
try JSONSerialization.data(withJSONObject:["pid":getpid(),"bundle":Bundle.main.bundleIdentifier ?? "none"]).write(to:ready,options:.atomic)
print("Owned source \(Bundle.main.bundleIdentifier ?? "none") PID \(getpid()) visible \(window.isVisible) window \(window.windowNumber)");fflush(stdout)
let timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) {_ in
    if FileManager.default.fileExists(atPath:control.path) {if !player.isPlaying {player.currentTime=0;player.play()}}
    else if player.isPlaying {player.stop()}
}
application.run()
withExtendedLifetime(timer) {}
