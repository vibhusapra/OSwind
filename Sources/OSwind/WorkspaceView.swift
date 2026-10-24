import SwiftUI
import OSwindCore
import AppKit

private let accent = OSwindTheme.accent
struct WorkspaceView: View {
    @EnvironmentObject var m: AppModel
    @FocusState private var searchFocused: Bool
    @State private var note = ""
    @State private var showNote = false
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:10) { Image(systemName:"wind").font(.system(size:26,weight:.semibold)).foregroundStyle(accent); Text("OSwind").font(.system(size:24,weight:.semibold,design:.rounded)) }.padding(.horizontal,22).padding(.top,28).padding(.bottom,6)
                Text("A little more of your memory.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,30)
                ForEach([("Memories","square.stack.3d.up"),("Ask","sparkles"),("Timeline","clock"),("Conversations","waveform"),("Saved","bookmark"),("Notes","note.text"),("Recaps","sun.max"),("Routines","calendar.badge.clock"),("Insights","chart.bar.xaxis")],id:\.0) { item in
                    Button { m.section = item.0; m.refresh() } label: { HStack(spacing:12) { Image(systemName:item.1).frame(width:20); Text(item.0); Spacer(); if item.0 == "Memories" { Text("\(m.stats.count)").font(.caption).monospacedDigit() } }.padding(.horizontal,14).padding(.vertical,11).background(m.section == item.0 ? accent.opacity(0.16) : .clear,in:RoundedRectangle(cornerRadius:9)) }.buttonStyle(.plain).padding(.horizontal,12).padding(.bottom,3)
                }
                Spacer()
                VStack(alignment:.leading,spacing:10) {
                    Label(m.demo ? "Sample workspace" : "Stored on this Mac",systemImage:"internaldrive").font(.caption.weight(.medium))
                    Text(m.storageUpdatedAt == nil ? "Measuring storage…" : ByteCountFormatter.string(fromByteCount:m.stats.bytes,countStyle:.file) + " of \(m.settings.privacy.maxStorageGB) GB").font(.caption2).foregroundStyle(.secondary)
                    ProgressView(value:min(1,Double(m.stats.bytes)/(Double(m.settings.privacy.maxStorageGB)*1e9))).tint(accent)
                    HStack { Label("\(m.settings.privacy.retentionDays) day retention",systemImage:"shield.lefthalf.filled").font(.caption2); Spacer() }
                }.padding(16).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12)).padding(12)
                Button { m.showSettings = true } label: { Label("Settings & setup",systemImage:"slider.horizontal.3").frame(maxWidth:.infinity,alignment:.leading).padding(14) }.buttonStyle(.plain).padding(.horizontal,10).padding(.bottom,10)
            }.frame(width:230).frame(maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor))
            Divider()
            VStack(spacing:0) {
                if let status=m.recapSaveStatus {
                    HStack {if m.savingRecap {ProgressView().controlSize(.small)};Text(status).font(.caption);Spacer();if !m.savingRecap {Button {m.recapSaveStatus=nil} label: {Image(systemName:"xmark")}.accessibilityLabel("Dismiss recap status")}}.padding(10).background(accent.opacity(0.06))
                }
                if let status=m.deletionStatus {
                    HStack {if m.deletingID != nil {ProgressView().controlSize(.small)};Text(status).font(.caption);Spacer();if m.deletingID==nil {Button {m.deletionStatus=nil} label: {Image(systemName:"xmark")}.accessibilityLabel("Dismiss deletion status")}}.padding(10).background(accent.opacity(0.06))
                }
                if m.openingMemoryID != nil { HStack { ProgressView().controlSize(.small); Text("Opening complete source…").font(.caption); Spacer(); Button("Cancel") { m.cancelOpeningMemory() } }.padding(10) }
                HStack {
                    HStack(spacing:7) { Circle().fill(m.isCapturing ? accent : .secondary).frame(width:7,height:7); Text(m.capture.running && m.audio.running ? "SCREEN + AUDIO" : m.capture.running ? "CAPTURING" : m.audio.running ? "AUDIO" : "PAUSED").font(.system(size:10,weight:.semibold,design:.monospaced)); Text("/ \(m.settings.profile.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if m.demo { Text("SAMPLE DATA").font(.system(size:10,weight:.bold,design:.monospaced)).padding(6).background(.orange.opacity(0.12),in:Capsule()) }
                    Button { showNote = true } label: { Label("Quick note",systemImage:"plus") }.buttonStyle(.borderless)
                    Button { m.toggleCapture() } label: { Label(m.isCapturing ? "Pause" : "Resume",systemImage:m.isCapturing ? "pause.fill" : "play.fill") }.buttonStyle(.bordered)
                }.padding(.horizontal,30).padding(.vertical,18)
                Divider().opacity(0.5)
                if m.section == "Ask" { AskView() }
                else if m.section == "Routines" { RoutinesView(model:m.routines) }
                else if m.section == "Insights" { InsightsView() }
                else { memories }
                Divider().opacity(0.5)
                HStack(spacing:8) { Image(systemName:"lock.shield").foregroundStyle(accent); Text(m.audio.running ? m.audio.status : m.capture.status).lineLimit(1); Spacer(); if m.refreshing { ProgressView().controlSize(.mini) }; Text("\(m.hits.count) \(m.hits.count == 1 ? "result" : "results") · \(Int(m.searchMS)) ms").monospacedDigit(); if !m.searchStrategy.isEmpty { Text(m.searchStrategy == "metal-exact-rerank" ? "Metal" : m.searchStrategy == "ann-exact-rerank" ? "Indexed" : "Exact").foregroundStyle(.tertiary) }; Text("⇧⌘Space").foregroundStyle(.tertiary) }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,11)
            }.background(Color(nsColor:.windowBackgroundColor))
        }
        .sheet(isPresented:$m.showSettings,onDismiss:{ m.refresh(); if m.searchFocusRequest != nil { m.searchFocusRequest = UUID() } }) { SettingsView(initialTab:m.settingsTab).id(m.settingsTab).environmentObject(m) }
        .sheet(isPresented:$m.showOnboarding) { OnboardingView().environmentObject(m) }
        .sheet(item:$m.selected) { MemoryDetail(memory:$0,query:m.selectedEvidenceQuery).environmentObject(m) }
        .sheet(isPresented:$showNote) { VStack(alignment:.leading,spacing:16) { Text("Keep a thought").font(.title2.weight(.semibold)); TextEditor(text:$note).font(.body).frame(width:500,height:220); HStack { Button("Cancel") { showNote = false }; Spacer(); Button("Save note") { m.addNote(note); note = ""; showNote = false }.buttonStyle(.borderedProminent).disabled(note.isEmpty) } }.padding(24) }
        .alert("OSwind",isPresented:Binding(get:{m.errorMessage != nil},set:{if !$0 {m.errorMessage = nil}})) { Button("OK") { m.errorMessage = nil } } message: { Text(m.errorMessage ?? "") }
    }
    private var memories: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text(m.section == "Memories" ? "Your day, within reach." : m.section).font(.system(size:32,weight:.medium,design:.rounded))
                    Text(m.section == "Conversations" ? "Local transcripts from the audio sources you enable." : m.section == "Timeline" ? "Scrub through the moments you saved." : "Find the thought, tab, or conversation you’re looking for.").foregroundStyle(.secondary)
                }; Spacer()
                if m.section == "Recaps" { Button("Create day recap") { m.section = "Ask"; m.range = "Today"; m.ask("Summarize today's work. List decisions and action items, with evidence citations.",summarize:true) }.buttonStyle(.borderedProminent) }
                if m.section == "Conversations" { Button(m.audio.running ? "Stop audio" : "Start audio") { Task {await m.toggleAudio()} }.buttonStyle(.borderedProminent) }
            }
            HStack(spacing:12) {
                Image(systemName:"magnifyingglass").foregroundStyle(accent)
                TextField("Search anything you’ve seen or heard…",text:$m.query).textFieldStyle(.plain).font(.system(size:16)).onSubmit { m.refresh() }.accessibilityIdentifier("memory-search").focused($searchFocused)
                    .task(id:m.searchFocusRequest) { if m.searchFocusRequest != nil && !m.showSettings { await Task.yield(); searchFocused = true } }
                if !m.query.isEmpty { Button { m.query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain) }
                Text("⌘K").font(.caption).foregroundStyle(.tertiary)
            }.padding(17).background(.background,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.08)))
            HStack(spacing:12) {
                Picker("Time",selection:$m.range) { ForEach(["All time","Today","Yesterday","7 days","Choose day"],id:\.self) { Text($0) } }.labelsHidden().frame(width:125)
                if m.range == "Choose day" { DatePicker("Date",selection:$m.date,displayedComponents:.date).labelsHidden().frame(width:120) }
                Picker("Application",selection:$m.appFilter) { Text("All apps").tag("All apps"); ForEach(m.stats.apps.keys.sorted(),id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:160)
                Spacer()
                Picker("Search mode",selection:$m.mode) { ForEach(SearchMode.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width:250)
            }
            QueryScopeControls(query:$m.query,filter:m.filter,enabled:$m.interpretQuery,knownApps:Array(m.stats.apps.keys),executionError:m.searchInputError)
            ForEach(m.searchWarnings,id:\.self) { warning in Label(warning,systemImage:"info.circle").font(.caption).foregroundStyle(.secondary) }
            if m.section == "Conversations" { Label(m.audio.status,systemImage:"waveform").font(.caption).foregroundStyle(.secondary) }
            if m.section == "Timeline" && !m.hits.isEmpty { TimelineStrip(hits:m.hits) { m.openMemory($0,query:m.activeSearchQuery) } }
            if let error = m.searchInputError {
                ContentUnavailableView { Label("Adjust query filters",systemImage:"line.3.horizontal.decrease.circle") } description: { Text(error) } actions: { Button("Use as search text") { m.interpretQuery = false } }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if m.hits.isEmpty {
                ContentUnavailableView { Label(m.query.isEmpty ? "A fresh start" : "No matching memories",systemImage:m.query.isEmpty ? "wind" : "magnifyingglass") } description: { Text(m.query.isEmpty ? "Resume capture, import an export, or save a note. Your memory stays on this Mac." : "Try fewer words, another app, or a wider time range.") } actions: { HStack { Button("Setup") { m.showSettings = true }; Button("Import JSON") { m.importData() } } }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView { LazyVGrid(columns:[GridItem(.adaptive(minimum:280,maximum:450),spacing:16)],spacing:16) { ForEach(m.hits) { hit in MemoryCard(hit:hit).environmentObject(m) } }.padding(.vertical,4) }
            }
        }.padding(30)
        .onChange(of:m.query) { m.refresh() }.onChange(of:m.mode) { m.refresh() }.onChange(of:m.interpretQuery) { m.refresh() }.onChange(of:m.appFilter) { m.refresh() }.onChange(of:m.range) { m.refresh() }.onChange(of:m.date) { m.refresh() }
    }
}
struct MemoryCard: View {
    @EnvironmentObject var m: AppModel
    let hit: SearchHit
    var memory: Memory { hit.memory }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Button { m.openMemory(memory,query:m.activeSearchQuery,passage:hit.passage) } label: {
                ZStack(alignment:.topLeading) {
                    if let path = memory.imagePath, let url = m.store.assetURL(path), let image = NSImage(contentsOf:url) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(height:150).frame(maxWidth:.infinity).background(.black.opacity(0.08)) }
                    else { VStack(alignment:.leading,spacing:12) { Image(systemName:memory.kind == .audio ? "waveform" : memory.kind == .summary ? "sun.max" : "text.alignleft").foregroundStyle(accent).font(.title3); EvidenceSnippetView(text:memory.text,query:m.activeSearchQuery,budget:m.activeSearchQuery.isEmpty ? 400 : 100,passage:hit.passage).font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary).lineLimit(5).frame(maxWidth:.infinity,alignment:.leading) }.padding(20).frame(height:150).background(accent.opacity(0.055)) }
                    Text(memory.recap != nil ? "LINKED RECAP":memory.visualRecording == nil ? memory.kind.rawValue.uppercased():"REPLAY").font(.system(size:8,weight:.semibold,design:.monospaced)).padding(5).background(.regularMaterial,in:RoundedRectangle(cornerRadius:4)).padding(8).frame(maxWidth:.infinity,alignment:.trailing)
                }
            }.buttonStyle(.plain)
            VStack(alignment:.leading,spacing:9) {
                HStack { Text(memory.app.isEmpty ? "Memory" : memory.app).font(.caption.weight(.medium)).foregroundStyle(accent); Spacer(); Text(memory.timestamp,style:.time).font(.caption2).foregroundStyle(.secondary) }
                Button { m.openMemory(memory,query:m.activeSearchQuery,passage:hit.passage) } label: { Text(memory.title.isEmpty ? "Untitled memory" : memory.title).font(.system(size:14,weight:.medium)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                if memory.imagePath != nil && !m.query.isEmpty { EvidenceSnippetView(text:memory.text,query:m.activeSearchQuery,budget:m.activeSearchQuery.isEmpty ? 400 : 100,passage:hit.passage).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                HStack { Text(memory.timestamp,style:.date).font(.caption2).foregroundStyle(.tertiary); Spacer(); if !m.query.isEmpty { Text(hit.match).font(.caption2).foregroundStyle(.secondary) }; Button { m.favorite(memory) } label: { Image(systemName:memory.favorite ? "bookmark.fill" : "bookmark").foregroundStyle(memory.favorite ? accent : .secondary) }.buttonStyle(.plain).accessibilityLabel(memory.favorite ? "Unsave memory" : "Save memory") }
            }.padding(15)
        }.background(.background,in:RoundedRectangle(cornerRadius:12)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.07)))
        .contextMenu { Button("Open memory") { m.openMemory(memory,query:m.activeSearchQuery,passage:hit.passage) }; Button(memory.favorite ? "Unsave" : "Save") { m.favorite(memory) }; Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(memory.text,forType:.string) }; Button("Delete memory",role:.destructive) { m.delete(memory) }.disabled(m.deletingID != nil || m.maintenanceBusy) }
    }
}
struct TimelineStrip: View {
    let hits: [SearchHit]
    let open: (Memory) -> Void
    @State private var position = 0.0
    var ordered: [Memory] { hits.map(\.memory).sorted {$0.timestamp < $1.timestamp} }
    var body: some View { VStack(spacing:8) { HStack(spacing:2) { ForEach(Array(ordered.enumerated()),id:\.element.id) { index,memory in Button { position = Double(index); open(memory) } label: { RoundedRectangle(cornerRadius:2).fill(memory.kind == .audio ? Color.orange.opacity(0.5) : accent.opacity(0.6)).frame(minWidth:2,maxWidth:.infinity).frame(height:CGFloat(16 + (index % 4)*6)) }.buttonStyle(.plain).help(memory.title) } }.frame(height:36); Slider(value:$position,in:0...Double(max(1,ordered.count-1)),step:1) { editing in if !editing { open(ordered[min(Int(position),ordered.count-1)]) } }; HStack { Text(ordered.first!.timestamp,style:.time); Spacer(); Text("\(ordered.count) captured moments"); Spacer(); Text(ordered.last!.timestamp,style:.time) }.font(.caption2).foregroundStyle(.secondary) }.padding(15).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12)) }
}
struct MemoryDetail: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let memory: Memory
    var query = ""
    @State private var boxes = false
    @State private var tags = ""
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { VStack(alignment:.leading,spacing:4) { Text(memory.title).font(.title2.weight(.semibold)); Text("\(memory.app) · \(memory.timestamp.formatted())").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                if memory.kind == .summary {RecapEvidenceView(memory:memory)}
                if !query.isEmpty && memory.visualRecording == nil {
                    VStack(alignment:.leading,spacing:8) {
                        Text("SEARCH EXCERPT").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                        EvidenceSnippetView(text:memory.text,query:query,budget:800,passage:m.selectedPassage).textSelection(.enabled).font(.callout)
                        Text("Ellipses mark omitted text. The complete source follows.").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(accent.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                }
                if let recording=memory.visualRecording { VideoReplayView(recording:recording,url:memory.videoPath.flatMap {m.store.assetURL($0)},initialTime:recording.frameTime(passage:m.selectedPassage,query:query),boxes:$boxes) }
                else if let path = memory.imagePath, let url = m.store.assetURL(path), let image = NSImage(contentsOf:url) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).overlay { if boxes { GeometryReader { geo in ForEach(Array(memory.regions.enumerated()),id:\.offset) { _,r in Rectangle().stroke(accent,lineWidth:1).frame(width:geo.size.width*r.width,height:geo.size.height*r.height).position(x:geo.size.width*(r.x+r.width/2),y:geo.size.height*(1-r.y-r.height/2)) } } } }.clipShape(RoundedRectangle(cornerRadius:9)) }
                if memory.kind == .audio { AudioPlaybackView(memory:memory,url:memory.audioPath.flatMap { m.store.assetURL($0) }) }
                if memory.visualRecording==nil && ((memory.transcript?.segments.isEmpty ?? true) || memory.transcript?.segments.allSatisfy({$0.text == "[REDACTED]"}) == true) { Text(memory.text).textSelection(.enabled).font(.system(size:14)).frame(maxWidth:.infinity,alignment:.leading).padding(.top,12) }
            }
            if let url = memory.url, let parsed = URL(string:url), ["https","http"].contains(parsed.scheme) { Link(url,destination:parsed).font(.caption).lineLimit(1) }
            HStack { TextField("Tags, comma separated",text:$tags).onSubmit { do { try m.store.setTags(memory.id,tags:tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }); m.refresh() } catch { m.errorMessage = error.localizedDescription } }; if memory.imagePath != nil || memory.visualRecording != nil { Toggle("OCR boxes",isOn:$boxes).toggleStyle(.checkbox) }; Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(memory.text,forType:.string) }; Button("Save") { m.favorite(memory) }; Button("Delete",role:.destructive) { m.delete(memory); dismiss() }.disabled(m.deletingID != nil || m.maintenanceBusy) }
            Text("Source \(memory.id)").font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
        }.padding(24).frame(width:850,height:760).onAppear { tags = memory.tags.joined(separator:", ") }
    }
}
struct AskView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.height < 700
        VStack(alignment:.leading,spacing:compact ? 12 : 18) {
            if compact {
                HStack {
                    Label("Ask your memory",systemImage:"sparkles").font(.system(size:24,weight:.medium,design:.rounded))
                    Spacer()
                    Text(m.settings.ai.provider.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose model") { m.showSettings = true }
                }
            } else {
                Label("ASK YOUR MEMORY",systemImage:"sparkles").font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(accent)
                Text("Pick up where your mind left off.").font(.system(size:32,weight:.medium,design:.rounded))
            }
            HStack {
                Menu {
                    if m.chats.isEmpty { Text("No saved conversations yet") }
                    ForEach(m.chats) { chat in Button("\(chat.title) · \(chat.turnCount)") { m.selectChat(chat.id) } }
                } label: { Label(m.chats.first(where: { $0.id == m.currentChatID })?.title ?? "Conversation history",systemImage:"clock.arrow.circlepath").lineLimit(1) }
                .disabled(m.asking)
                Button("New",systemImage:"square.and.pencil") { m.newChat() }.disabled(m.asking)
                Spacer()
                if m.currentChatID != nil {
                    Button("Export",systemImage:"square.and.arrow.up") { m.exportChat() }.disabled(m.asking)
                    Button("Delete",systemImage:"trash",role:.destructive) { m.deleteCurrentChat() }.disabled(m.asking)
                }
            }.buttonStyle(.bordered)
            if !compact { HStack { Text(m.settings.ai.provider.label).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Choose model") { m.showSettings = true } } }
            HStack(spacing:12) {
                Text("Search within").font(.caption).foregroundStyle(.secondary)
                Picker("Answer time range",selection:$m.range) { ForEach(["All time","Today","Yesterday","7 days","Choose day"],id:\.self) { Text($0) } }.labelsHidden().frame(width:125)
                if m.range == "Choose day" { DatePicker("Answer date",selection:$m.date,displayedComponents:.date).labelsHidden().frame(width:120) }
                Picker("Answer application",selection:$m.appFilter) { Text("All apps").tag("All apps"); ForEach(m.stats.apps.keys.sorted(),id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:160)
                Spacer()
            }.disabled(m.asking)
            HStack { TextField(m.chatTurns.isEmpty ? "What did we decide about…" : "Ask a follow-up…",text:$m.question).textFieldStyle(.plain).onSubmit { m.ask() }.onChange(of:m.question) { m.answerInputError = nil }; Button { m.ask() } label: { Image(systemName:"arrow.up") }.accessibilityLabel("Ask question").buttonStyle(.borderedProminent).disabled(m.asking || m.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }.padding(compact ? 14 : 18).background(.background,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.1)))
            QueryScopeControls(query:$m.question,filter:m.filter,enabled:$m.interpretQuery,knownApps:Array(m.stats.apps.keys),executionError:m.answerInputError).disabled(m.asking)
            HStack { Button("Recap today") { m.range = "Today"; m.ask("Summarize today's work with decisions, open questions and next steps. Cite evidence.",summarize:true) }; Button("Draft a standup") { m.range = "Today"; m.ask("Draft a standup: completed work, in progress, and blockers. Only use recorded evidence.",summarize:true) }; Button("Action items") { m.ask("Extract action items, owners and deadlines explicitly stated in recorded evidence. Mark missing details.",summarize:true) } }.buttonStyle(.bordered).disabled(m.asking)
            if m.asking { HStack { ProgressView().controlSize(.small); Text("Reading your selected memories…").foregroundStyle(.secondary); Spacer(); Button("Cancel") { m.cancelAnswer() } } }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:24) {
                        if !m.chatTurns.isEmpty {
                            ForEach(m.chatTurns) { turn in
                                VStack(alignment:.leading,spacing:12) {
                                    Text(turn.question).font(.system(size:15,weight:.medium)).textSelection(.enabled).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(accent.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
                                    RecordedScopeView(filter:turn.filter,timeZone:turn.timeZone)
                                    AnswerCard(answer:turn.answer,question:turn.question)
                                    Text(turn.timestamp.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
                                }.id(turn.id)
                            }
                        } else if let answer = m.answer { AnswerCard(answer:answer) }
                        else { VStack(alignment:.leading,spacing:12) { Text("Evidence comes first.").font(.title3.weight(.medium)); Text("Ask about a conversation, recover a forgotten link, or turn today’s activity into a recap. Saved conversations stay on this Mac.").foregroundStyle(.secondary); Text("Follow-ups recheck recorded sources within your current filters. Deleting evidence also removes saved chat answers that cited it.").font(.caption).foregroundStyle(.secondary) }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(accent.opacity(0.06),in:RoundedRectangle(cornerRadius:12)) }
                    }
                }.onChange(of:m.chatTurns.last?.id) { _, _ in if let id = m.chatTurns.last?.id { reader.scrollTo(id,anchor:.bottom) } }
            }
        }.padding(compact ? 24 : 32)
        }.onAppear { m.refreshChats() }
    }
}
struct AnswerCard: View {
    @EnvironmentObject var m: AppModel
    let answer: Answer
    var question = ""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            ForEach(answer.warnings,id:\.self) { warning in Label(warning,systemImage:"info.circle").font(.caption).foregroundStyle(.secondary) }
            Text(answer.text).textSelection(.enabled).font(.system(size:15)).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading)
            HStack { Text("\(answer.provider) · \(String(format:"%.1f",answer.duration)) s · \(answer.sources.count) sources").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save linked recap") {m.saveAnswer(answer)}.disabled(m.savingRecap || answer.sources.isEmpty); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer.text,forType:.string) } }
            if !answer.sources.isEmpty {
                DisclosureGroup("Check \(answer.sources.count) sources") {
                    ForEach(Array(answer.sources.enumerated()),id:\.element.id) { i,hit in
                        Button { m.openMemory(hit.memory,query:question,passage:hit.passage) } label: {
                            VStack(alignment:.leading,spacing:7) {
                                HStack { Text("[\(i+1)]").monospaced(); Text(hit.memory.title).lineLimit(1); Spacer(); Text(hit.memory.app).foregroundStyle(.secondary) }
                                EvidenceSnippetView(text:hit.memory.text,query:question,passage:hit.passage).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                            }.padding(10).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain)
                    }
                }.font(.caption)
            }
        }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:12))
    }
}
struct InsightsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View { ScrollView { VStack(alignment:.leading,spacing:24) {
        Text("A clearer view of your day.").font(.system(size:32,weight:.medium,design:.rounded))
        Text("Capture counts reflect saved evidence, not measured time at work.").foregroundStyle(.secondary)
        HStack(spacing:16) { metric("Memories",m.stats.count.formatted(),"square.stack.3d.up"); metric("Apple vectors",m.stats.embedded.formatted(),"point.3.connected.trianglepath.dotted"); metric("Local storage",m.storageUpdatedAt == nil ? "…" : ByteCountFormatter.string(fromByteCount:m.stats.bytes,countStyle:.file),"internaldrive") }
        if let updated = m.storageUpdatedAt { Text("Storage checked \(updated.formatted(date:.omitted,time:.shortened)).").font(.caption).foregroundStyle(.secondary) }
        Text("CAPTURED APPLICATIONS").font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
        ForEach(m.stats.apps.sorted {$0.value > $1.value},id:\.key) { app,count in HStack { Text(app).frame(width:140,alignment:.leading); GeometryReader { geo in RoundedRectangle(cornerRadius:4).fill(accent.opacity(0.6)).frame(width:max(2,geo.size.width*Double(count)/Double(max(1,m.stats.count)))) }.frame(height:18); Text("\(count)").monospacedDigit().frame(width:55,alignment:.trailing) }.padding(.vertical,4) }
        Divider()
        Text("Capture health").font(.title3.weight(.medium)); HStack(spacing:25) { Text("\(m.capture.metrics.saved) saved"); Text("\(m.capture.metrics.unchanged) duplicates skipped"); Text("\(m.capture.metrics.excluded) excluded"); Text("\(m.capture.metrics.errors) errors") }.font(.caption).foregroundStyle(.secondary)
        Text("\(Int(m.capture.metrics.lastLatencyMS)) ms last capture · \(m.settings.profile.interval.formatted()) s base interval").font(.caption).foregroundStyle(.secondary)
        Button("Run retention cleanup") { m.maintain() }
    }.padding(32) } }
    private func metric(_ title: String,_ value: String,_ icon: String) -> some View { VStack(alignment:.leading,spacing:14) { Image(systemName:icon).foregroundStyle(accent); Text(value).font(.system(size:28,weight:.medium,design:.rounded)); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading).padding(22).background(.background,in:RoundedRectangle(cornerRadius:12)) }
}
