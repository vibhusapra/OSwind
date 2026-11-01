import SwiftUI
import AppKit
import AVKit
import OSwindCore

struct WorkflowView:View {
    @ObservedObject var model:WorkflowModel
    var openMemories:()->Void
    var openSource:((WorkflowSourceBinding)->Void)?=nil
    @State private var setup=false
    @State private var player:AVPlayer?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text("Show how it happened.").font(.system(size:32,weight:.medium,design:.rounded))
                    Text("Turn retained screens into a clear, narrated walkthrough.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add a screen",action:openMemories).disabled(model.busy || model.steps.count>=WorkflowDraft.maximumSteps)
                Button("Export walkthrough…",action:chooseDestination).buttonStyle(.borderedProminent).tint(OSwindTheme.accent).disabled(!model.canExport)
            }
            HStack(spacing:10) {
                Label("LOCAL KOKORO",systemImage:"waveform").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(OSwindTheme.accent)
                Text("af_heart · 1×").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.steps.count) / 8 steps · up to 2 minutes").font(.caption).foregroundStyle(.secondary)
                Button {setup.toggle()} label: {Label(model.helperReady ? "Helper found":"Set up narration",systemImage:model.helperReady ? "checkmark.circle":"wrench.and.screwdriver")}.font(.caption)
            }.padding(14).background(OSwindTheme.accent.opacity(0.065),in:RoundedRectangle(cornerRadius:10))
            if setup || !model.helperReady {narrationSetup}
            if model.steps.isEmpty {
                VStack(spacing:16) {
                    Image(systemName:"rectangle.stack.badge.play").font(.system(size:44,weight:.light)).foregroundStyle(OSwindTheme.accent)
                    Text("A useful moment becomes a useful guide.").font(.title2.weight(.medium))
                    Text("In Memories, open a screen’s menu and choose Add to workflow.\nPick a replay frame, write what to explain, and arrange the steps.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Choose a retained screen",action:openMemories).buttonStyle(.bordered)
                    Text("Scripts, original narration, captions and source links travel with your video.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }else {
                HStack {
                    TextField("Walkthrough title",text:$model.title).textFieldStyle(.plain).font(.title2.weight(.medium)).disabled(!model.canEdit).accessibilityIdentifier("workflow-title")
                    Button("Clear draft") {model.reset()}.disabled(!model.canEdit)
                }
                ScrollView {
                    LazyVStack(spacing:16) {
                        ForEach(Array(model.steps.enumerated()),id:\.element.id) {index,item in step(item,index:index)}
                        if let url=model.completedURL,let duration=model.completedDuration {
                            VStack(alignment:.leading,spacing:12) {
                                Label("Export ready · \(String(format:"%.1f",duration)) seconds",systemImage:"checkmark.seal").font(.headline).foregroundStyle(OSwindTheme.accent)
                                if let player {VideoPlayer(player:player).frame(minHeight:240,maxHeight:360)}
                                HStack {Text("Independent, unencrypted copy").font(.caption).foregroundStyle(.secondary);Spacer();Button("Show exported folder") {NSWorkspace.shared.activateFileViewerSelecting([url])}}
                            }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:12))
                        }
                    }.padding(.vertical,3)
                }
            }
            HStack(spacing:10) {
                if model.busy {ProgressView().controlSize(.small)}
                Text(model.status).font(.callout).textSelection(.enabled)
                Spacer()
                if model.busy {Button("Cancel") {model.cancel()}}
            }
            Text("Export saves an independent, unencrypted folder. Drafts stay in memory and clear on lock or privacy changes.").font(.caption).foregroundStyle(.secondary)
        }.padding(28)
        .onChange(of:model.completedURL) {_,url in player?.pause();player=url.map {AVPlayer(url:$0.appendingPathComponent("workflow.mp4"))}}
        .onDisappear {player?.pause()}
    }
    private var narrationSetup:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Local narration setup").font(.headline)
            Text("Choose an installed kokoro-narrate helper with its local model. Export runs offline and verifies the voice, measured timing and complete audio.").font(.callout).foregroundStyle(.secondary)
            HStack {TextField("Absolute path to kokoro-narrate",text:$model.helperPath).textFieldStyle(.roundedBorder);Button("Choose helper…",action:chooseHelper)}.disabled(model.busy)
            Label(model.helperReady ? "Executable found. Model readiness is checked during export.":"Local helper required before export.",systemImage:model.helperReady ? "checkmark.circle":"info.circle").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
    }
    private func step(_ item:WorkflowEditorStep,index:Int)->some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:10) {
                Text(String(format:"%02d",index+1)).font(.system(.caption,design:.monospaced).weight(.bold)).foregroundStyle(OSwindTheme.accent)
                TextField("Step title",text:Binding(get:{model.steps.first {$0.id==item.id}?.step.title ?? ""},set:{model.edit(item.id,title:$0)})).textFieldStyle(.plain).font(.headline)
                Spacer()
                Button {model.move(item.id,by:-1)} label: {Image(systemName:"arrow.up")}.disabled(index==0).accessibilityLabel("Move step up")
                Button {model.move(item.id,by:1)} label: {Image(systemName:"arrow.down")}.disabled(index==model.steps.count-1).accessibilityLabel("Move step down")
                Button {model.remove(item.id)} label: {Image(systemName:"trash")}.accessibilityLabel("Remove step")
            }
            HStack(alignment:.top,spacing:20) {
                VStack(alignment:.leading,spacing:8) {
                    if let image=NSImage(data:item.frame.png) {Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(maxWidth:.infinity).frame(height:146).background(.black.opacity(0.07),in:RoundedRectangle(cornerRadius:7))}
                    Text(item.frame.app.isEmpty ? "Retained screen":item.frame.app).font(.caption.weight(.medium)).lineLimit(1)
                    Text(item.frame.timestamp.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
                    if item.frame.choices.count>1 {
                        Picker("Replay frame",selection:Binding(get:{item.step.source.frameOrdinal},set:{model.selectFrame(stepID:item.id,ordinal:$0)})) {
                            ForEach(item.frame.choices,id:\.ordinal) {choice in Text("\(choice.ordinal+1) · \(String(format:"%.2f",choice.time ?? 0)) s").tag(choice.ordinal)}
                        }.font(.caption)
                    }else {Label("Retained snapshot",systemImage:"link").font(.caption2).foregroundStyle(.secondary)}
                    HStack {if let openSource {Button("Open source") {openSource(item.step.source)}};Button("Refresh frame") {model.selectFrame(stepID:item.id,ordinal:item.step.source.frameOrdinal)}}.font(.caption2)
                }.frame(width:250)
                VStack(alignment:.leading,spacing:8) {
                    Text("What should the viewer understand?").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextEditor(text:Binding(get:{model.steps.first {$0.id==item.id}?.step.narration ?? ""},set:{model.edit(item.id,narration:$0)})).font(.body).scrollContentBackground(.hidden).frame(minHeight:140).padding(10).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8)).accessibilityLabel("Narration for step \(index+1)")
                    Text("\(item.step.narration.utf8.count) / 4,000 bytes · spoken exactly as written").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.07))).disabled(!model.canEdit)
    }
    private func chooseDestination() {
        guard model.canExport else {return}
        let panel=NSSavePanel();panel.title="Export narrated walkthrough";panel.message="Create a new, independent, unencrypted folder containing your video, scripts and retained frames.";panel.nameFieldStringValue="OSwind Walkthrough";panel.canCreateDirectories=true
        guard panel.runModal() == .OK,let url=panel.url else {return};model.export(to:url)
    }
    private func chooseHelper() {
        let panel=NSOpenPanel();panel.title="Choose local Kokoro helper";panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.showsHiddenFiles=true
        guard panel.runModal() == .OK,let url=panel.url else {return};model.helperPath=url.path
    }
}
