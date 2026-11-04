import SwiftUI
import OSwindCore

struct MeetingWorkspaceView:View {
    @ObservedObject var calendar:MeetingsModel
    @ObservedObject var recordings:RecordedMeetingsModel
    @State private var tab=0
    var body:some View {
        VStack(spacing:0) {
            Picker("Meeting workspace",selection:$tab) {Text("Recordings").tag(0);Text("Upcoming").tag(1)}.pickerStyle(.segmented).frame(maxWidth:360).padding(.top,20)
            if tab==0 {RecordedMeetingsView(model:recordings)}else {MeetingsView(model:calendar)}
        }
    }
}
struct RecordedMeetingsView:View {
    @ObservedObject var model:RecordedMeetingsModel
    @EnvironmentObject private var m:AppModel
    @State private var appearance:UUID?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Keep the conversation.").font(.system(size:30,weight:.medium,design:.rounded))
                    Text("Recording sessions, linked to their original transcripts and clips.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import audio") {m.importAudio()}.disabled(m.importingAudio || !m.libraryWorkAvailable)
                Button(m.audio.running ? "Stop & transcribe":"Record meeting") {
                    if !m.settings.audioEnabled && !m.settings.systemAudioEnabled {m.settingsTab="Audio";m.showSettings=true}
                    else {Task {await m.toggleAudio()}}
                }.buttonStyle(.borderedProminent).disabled(!m.libraryWorkAvailable || m.voice.busy)
            }
            HStack {
                Label(model.status,systemImage:"waveform").font(.callout)
                Spacer();if model.busy {ProgressView().controlSize(.small)}
                Button("Refresh") {model.refresh()}.disabled(model.busy)
                Button("Audio setup") {m.settingsTab="Audio";m.showSettings=true}
            }
            if m.audio.hasActiveWork || m.audio.status != "Audio off" {Text(m.audio.status).font(.caption).foregroundStyle(.secondary)}
            if m.importingAudio {HStack {ProgressView().controlSize(.small);Text(m.audioImportStatus.isEmpty ? "Importing audio…":m.audioImportStatus);Button("Cancel") {m.cancelAudioImport()}}.font(.caption)}
            if let error=model.error {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.orange).font(.callout)}
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label(model.hasOlder ? "Recent recordings are hidden":"Your recordings will appear here",systemImage:"waveform")
                } description: {
                    Text(model.hasOlder ? "Your privacy rules hide the newest clips. Older recordings may still be available.":"Record with your chosen microphone or system-audio settings, or import a file. Calendar access is optional. Recording IDs keep clips together; nearby timestamps do not merge separate conversations.")
                } actions: {
                    if model.hasOlder {Button("Load older recordings") {model.loadOlder()}.disabled(model.busy)}
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }else {
                HStack(alignment:.top,spacing:16) {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:8) {
                            ForEach(model.sessions) {session in
                                let countLabel=String(session.sources.count)+(session.sources.count==1 ? " clip loaded":" clips loaded")
                                Button {model.selectedID=session.id} label: {
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(model.title(for:session)).font(.headline).lineLimit(2)
                                        if model.nameSummaries[session.id]?.hasConflicts==true {Label("Review saved names",systemImage:"exclamationmark.bubble").font(.caption2).foregroundStyle(.secondary)}
                                        Text(session.first,format:.dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                        Text(countLabel+(session.hasUnobservedTimes ? " · saved dates":"")).font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                                        .background(model.selectedID==session.id ? OSwindTheme.accent.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:10))
                                }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(model.title(for:session)+", "+countLabel)
                            }
                            if model.hasOlder {Button("Load older recordings") {model.loadOlder()}.disabled(model.busy).padding(.vertical,10)}
                        }.padding(.trailing,10)
                    }.frame(minWidth:200,idealWidth:230,maxWidth:270)
                    Divider()
                    if let session=model.selected {detail(session).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}else {ContentUnavailableView("Choose a session",systemImage:"waveform")}
                }
            }
            Text("New recordings refresh automatically while this view is active. Only loaded clips are counted. Live spans preserve observed gaps and overlapping audio channels; import dates are not original meeting times. Speaker labels remain local to each source recording.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(26).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .onAppear {appearance=model.activate()}.onDisappear {if let appearance {model.deactivate(appearance)}}
    }
    private func detail(_ session:RecordedMeeting)->some View {
        VStack(alignment:.leading,spacing:12) {
            RecordingNameSection(names:model.names,archive:model,originalTitle:session.title)
            HStack {
                Button("Ask about recording") {model.askSelected()}.disabled(model.busy || m.asking)
                Button("Recap") {model.askSelected(summarize:true)}.disabled(model.busy || m.asking)
            }
            Text(session.sources.first?.belongsToSession == true ? "Ask searches the full recording session. Recaps use a bounded sample and excerpts.":"Ask and recap use this source version.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if session.observedSeconds>0 {Text("\(duration(session.observedSeconds)) observed across the loaded live clips").font(.callout).foregroundStyle(.secondary)}
            if session.hasUnobservedTimes {Text("Some clips have no recorded interval. Their saved or import date does not establish when a meeting happened.").font(.caption).foregroundStyle(.secondary)}
            Divider()
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(session.sources) {source in
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:5) {
                                Text(source.title.isEmpty ? "Audio recording":source.title).font(.headline).lineLimit(2)
                                Text(source.app+(source.hasObservedInterval ? " · recorded ":" · saved ")+source.timestamp.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                                Text(source.duration>0 ? duration(source.duration)+" source clip":"Duration unavailable").font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            Button("Open transcript") {model.open(source)}.disabled(model.busy || m.openingMemoryID != nil)
                        }.padding(12).background(.quaternary.opacity(0.18),in:RoundedRectangle(cornerRadius:10))
                    }
                }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    private func duration(_ seconds:Double)->String {
        let total=Int(max(0,seconds.rounded()))
        return total>=3600 ? "\(total/3600)h \((total%3600)/60)m":total>=60 ? "\(total/60)m \(total%60)s":"\(total)s"
    }
}
