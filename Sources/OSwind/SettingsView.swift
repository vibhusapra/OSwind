import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement
import OSwindCore

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var tab = "Capture"
    @State private var key = ""
    @State private var keyStatus = ""
    @State private var deleteConfirm = false
    @State private var showHistoryErasure=false
    @State private var downloadName = "qwen3-embedding:0.6b"
    init(initialTab: String = "Capture") { _tab = State(initialValue:initialTab) }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("Make OSwind yours.").font(.title2.weight(.medium)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("Settings",selection:$tab) { ForEach(["Capture","Privacy","Models","Audio","Connect","Data"],id:\.self) { Text($0) } }.pickerStyle(.segmented)
            ScrollView { Form {
                switch tab {
                case "Capture": capture
                case "Privacy": privacy
                case "Models": models
                case "Audio": audio
                case "Connect": connect
                default: data
                }
            }.formStyle(.grouped) }
        }.padding(24).frame(width:760,height:720)
        .sheet(isPresented:$showHistoryErasure) {HistoryErasureView().environmentObject(m)}
        .alert("Delete all local memories?",isPresented:$deleteConfirm) { Button("Cancel",role:.cancel) {}; Button("Delete everything",role:.destructive) { m.pauseAll(discardReplay:true); m.cancelAnswer();m.routines.cancel(); do { try m.store.deleteAll();m.routines.reload(); m.refreshChats(); m.answer = nil; m.invalidateStorageEstimate(); m.refresh(forceStatistics:true) } catch { m.errorMessage = error.localizedDescription } } } message: { Text("Deletes the local index, screenshots, replay clips, audio, saved notes, recaps, routines, routine results, and conversations. Exports you saved elsewhere remain.") }
    }
    private var capture: some View {
        Group {
            Section("Capture profile") {
                Picker("Visual memory",selection:$m.settings.visualCaptureMode) { Text("Snapshots").tag(VisualCaptureMode.snapshots); Text("Replay · HEVC clips").tag(VisualCaptureMode.replay) }
                Picker("Profile",selection:$m.settings.profile) { ForEach(CaptureProfile.allCases,id:\.self) { Text("\($0.rawValue.capitalized) · \(m.settings.visualCaptureMode == .replay ? $0.replayInterval(lowPower:false,thermalLimited:false).formatted():$0.interval.formatted()) s").tag($0) } }
                Text(m.settings.visualCaptureMode == .replay ? "Focused-window replay: Light 1280 px / 5 s; Balanced 1920 px / 1 s; Detailed 2560 px / 0.5 s. Hardware HEVC clips include timed OCR and accessibility text. Clips become searchable after finalization, usually within five seconds. Unchanged stream frames are omitted. Low Power Mode and thermal pressure reduce the rate; inactivity pauses capture." : "Light: 1280 px / 20 s. Balanced: 1920 px / 5 s. Detailed: 2560 px / 2 s. Changes trigger captures; duplicate frames are skipped. Low Power Mode and thermal pressure slow capture, and two minutes of inactivity pauses it.").font(.caption).foregroundStyle(.secondary)
                Toggle("Capture all displays",isOn:$m.settings.allDisplays)
                Text(m.settings.visualCaptureMode == .replay && m.settings.allDisplays ? "All-display replay is not available yet; this combination uses snapshots. Turn off all displays for replay." : "Default: focused window only. Full-display mode masks all browser windows and excluded applications; background URLs cannot be verified.").font(.caption).foregroundStyle(.secondary)
                Toggle("Resume capture when OSwind opens",isOn:$m.settings.captureOnLaunch)
                Toggle("Open at login",isOn:Binding(get:{SMAppService.mainApp.status == .enabled},set:{m.login($0)}))
            }
            Section("macOS access") {
                permissionRow("Screen Recording",ready:CGPreflightScreenCaptureAccess(),detail:"Required to capture screen pixels and system audio.",url:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                permissionRow("Accessibility",ready:AXIsProcessTrusted(),detail:"Optional for native apps; required by default for browser URL privacy rules.",url:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                Button("Request Screen Recording") { _ = CGRequestScreenCaptureAccess() }
                Button("Request Accessibility") { let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary; _ = AXIsProcessTrustedWithOptions(options) }
                Text("Global search: ⇧⌘Space. Pause/resume in app: ⇧⌘P. OSwind shows capture status in the menu bar.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var privacy: some View {
        Group {
            Section("Exclude before capture") {
                multiline("Application bundle IDs",value:Binding(get:{m.settings.privacy.excludedApps.joined(separator:"\n")},set:{m.settings.privacy.excludedApps = entries($0)}))
                multiline("Website domains",value:Binding(get:{m.settings.privacy.excludedDomains.joined(separator:"\n")},set:{m.settings.privacy.excludedDomains = entries($0)}))
                multiline("Window title contains",value:Binding(get:{m.settings.privacy.excludedTitles.joined(separator:"\n")},set:{m.settings.privacy.excludedTitles = entries($0)}))
                Toggle("Skip browser capture if URL is unavailable",isOn:$m.settings.privacy.requireBrowserContext)
            }
            Section("Erase recorded history") {
                Button("Erase by time, app or website…") {showHistoryErasure=true}.disabled(m.libraryTransfer.busy)
                Text("Preview matching records, then erase their text, retained media and dependent answers. Capture pauses before preview.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Protect stored evidence") {
                Toggle("Redact common secrets and sensitive numbers",isOn:$m.settings.privacy.redactSecrets)
                Text("Matches common API tokens, password assignments, card-like numbers, SSNs and private key blocks. Redacted captures keep text only; the original image is discarded. Pattern filtering is best effort and does not detect every kind of personal information.").font(.caption).foregroundStyle(.secondary)
                Toggle("Keep screenshots and replay clips alongside text",isOn:$m.settings.privacy.retainImages)
                Text("Screen, audio, and model access are separate. Audio segments are discarded when a foreground privacy rule is active at segment completion. Use Pause and Stop audio for sensitive activity.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var models: some View {
        Group {
            Section("Answer engine") {
                Picker("Provider",selection:$m.settings.ai.provider) { ForEach(AIProvider.allCases,id:\.self) { Text($0.label).tag($0) } }.onChange(of:m.settings.ai.provider) { _,provider in key = ""; keyStatus = ""; if provider == .ollama { m.settings.ai.endpoint = "http://127.0.0.1:11434"; m.settings.ai.model = AIConfiguration.defaultLocalModel }; if provider == .anthropic { m.settings.ai.endpoint = "https://api.anthropic.com"; m.settings.ai.model = "" }; if provider == .compatible { m.settings.ai.endpoint = "https://api.openai.com/v1"; m.settings.ai.model = "" } }
                Text("Evidence mode needs no model. Apple Intelligence requires macOS 26 and enabled model assets. Ollama uses local Metal acceleration on Apple Silicon. Choose the search model separately below; Apple capture indexing stays available.").font(.caption).foregroundStyle(.secondary)
                if [.ollama,.compatible,.anthropic].contains(m.settings.ai.provider) {
                    TextField("Server base URL",text:$m.settings.ai.endpoint)
                    TextField("Model ID",text:$m.settings.ai.model)
                    if m.settings.ai.provider != .ollama {
                        Toggle("Allow selected text context to leave this Mac",isOn:$m.settings.ai.allowRemote)
                        SecureField("API key (saved in Keychain)",text:$key)
                        HStack { Button("Save API key") { do { try SecretStore.set(m.settings.ai.provider.rawValue,value:key); key = ""; keyStatus = "Saved in macOS Keychain" } catch { keyStatus = error.localizedDescription } }.disabled(key.isEmpty); Button("Remove saved key") { try? SecretStore.set(m.settings.ai.provider.rawValue,value:""); keyStatus = "Key removed" } }
                        Text(keyStatus).font(.caption)
                        Text("BYOK API billing is separate from a chat subscription. Only retrieved text is sent; screenshots and raw audio are not included. No automatic cloud fallback.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Discover local models") { m.inspectLocalModels() }
                    if m.settings.ai.provider == .ollama, !m.installedModels.isEmpty {
                        Picker("Installed chat model",selection:$m.settings.ai.model) {
                            ForEach(m.installedModels.filter { !$0.isRemote && ($0.capabilities?.contains("completion") ?? true) }) { model in Text(model.name).tag(model.name) }
                        }
                    }
                }
            }
            Section("Search model") {
                Picker("Semantic retrieval",selection:$m.settings.search.provider) {
                    Text("Apple · lightweight English").tag(EmbeddingProvider.apple)
                    Text("Ollama · local GPU embeddings").tag(EmbeddingProvider.ollama)
                }
                Text("The Apple path is ready without downloads. A multilingual embedding model can improve meaning-based recall; it uses more memory and energy. New captures remain searchable by text while its separate index is built.").font(.caption).foregroundStyle(.secondary)
                Picker("Search strategy",selection:$m.settings.search.indexPolicy) {
                    Text("Automatic").tag(SearchIndexPolicy.automatic)
                    Text("Exact · exhaustive scan").tag(SearchIndexPolicy.exact)
                    Text("Indexed · accelerated").tag(SearchIndexPolicy.indexed)
                }
                Text("Indexed search reranks candidates using the original local vectors. Exact scans every vector in the selected range. Automatic uses indexing for larger archives and exact scans for filtered ranges.").font(.caption).foregroundStyle(.secondary)
                Toggle("Allow additional indexing in Low Power Mode",isOn:$m.settings.search.indexOnLowPower)
                if m.settings.search.provider == .ollama {
                    TextField("Local model server",text:$m.settings.search.endpoint)
                    TextField("Embedding model ID",text:$m.settings.search.model)
                    if !m.installedModels.isEmpty {
                        Picker("Installed embedding model",selection:$m.settings.search.model) {
                            ForEach(m.installedModels.filter { !$0.isRemote && ($0.capabilities?.contains("embedding") ?? $0.name.contains("embed")) }) { model in Text(model.name).tag(model.name) }
                        }
                    }
                }
                Button(m.indexing ? "Indexing…" : "Build / resume embedding vectors") { m.rebuildIndex() }.disabled(m.indexing)
                Text("Long records use overlapping passages across the complete text. Indexes are pinned to the installed model digest and kept on this Mac. Changing models never mixes incompatible vectors. Completed sources survive cancellation; deleted or changed source memories cannot be restored by an old indexing job.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Prepare fast retrieval") { m.prepareFastIndex() }.disabled(m.indexing || m.settings.search.indexPolicy == .exact); if m.indexing { Button("Cancel") { m.cancelIndexing() } } }
                if m.indexing { ProgressView(value:m.indexProgress) }
                Text(m.indexStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Local model library") {
                HStack { Button(m.startingModelServer ? "Starting…" : "Start local server") { m.startModelServer() }.disabled(m.startingModelServer); Button("Check local server") { m.inspectLocalModels() }; Text(m.modelStatus).font(.caption).foregroundStyle(.secondary) }
                ForEach(m.installedModels) { model in HStack { Text(model.name); Spacer(); Text(model.isRemote ? "Cloud alias · unavailable in local mode" : ByteCountFormatter.string(fromByteCount:model.size,countStyle:.file)).font(.caption).foregroundStyle(.secondary) } }
                if !m.localRuntime.isEmpty { Text(m.localRuntime).font(.caption).textSelection(.enabled) }
                HStack { TextField("Model to download",text:$downloadName); Button("Download") { m.downloadModel(downloadName) }.disabled(m.pullingModel != nil || downloadName.isEmpty) }
                HStack { Button("Embedding · 0.6B") { downloadName = "qwen3-embedding:0.6b" }; Button("Chat · 4B") { downloadName = AIConfiguration.defaultLocalModel } }.font(.caption)
                if let model = m.pullingModel {
                    Text("Downloading \(model)").font(.caption)
                    if let fraction = m.pullProgress?.fraction { ProgressView(value:fraction) } else { ProgressView().controlSize(.small) }
                    HStack { Text(m.pullProgress?.status ?? "Connecting…").font(.caption); Spacer(); Button("Cancel download") { m.cancelModelDownload() } }
                }
                Text("Install and start Ollama with scripts/setup-models.sh if the local server is unavailable. Downloads use Ollama’s model registry; captured content is never included in a model download. Local modes reject known cloud-backed aliases. Whisper setup remains in the script.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audio: some View {
        Group {
            Section("Capture and playback") {
                Toggle("Microphone",isOn:$m.settings.audioEnabled)
                Toggle("System audio",isOn:$m.settings.systemAudioEnabled)
                Toggle("Retain audio clips for playback",isOn:$m.settings.retainAudio)
                HStack { Button(m.audio.running ? "Stop audio" : "Start audio") { if m.audio.running { m.audio.finish() } else { Task { await m.audio.start() } } }; Text(m.audio.status).font(.caption).foregroundStyle(.secondary) }
                Text("Live audio is transcribed in 30-second segments. Pause discards pending capture. Clip retention applies to recordings and imports; detected secrets suppress the raw clip. Stop before private conversations.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Import a recording") {
                HStack { Button("Import audio file…") { m.importAudio() }.disabled(m.importingAudio); if m.importingAudio { ProgressView().controlSize(.small); Button("Cancel import") { m.cancelAudioImport() } } }
                if !m.audioImportStatus.isEmpty { Text(m.audioImportStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Toggle("Identify speakers in imported recordings",isOn:$m.settings.diarization.enabled).disabled(!SpeakerDiarizer.supported && !m.settings.diarization.enabled)
                if m.settings.diarization.enabled {
                    NativeModelDownloadView(setup:m.nativeModels,kind:.speakers)
                    TextField("Community-1 model directory",text:$m.settings.diarization.modelDirectory)
                    Button("Choose speaker model directory…") {
                        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false
                        if panel.runModal() == .OK,let url=panel.url { m.settings.diarization.modelDirectory=url.path }
                    }
                    Button("Release resident speaker model") { Task { try? await m.audio.speakers.unload() } }
                    Text("Labels apply within this recording. Mixed or uncertain spans stay unassigned; no voice profiles are saved. Requires macOS 15+. Live speaker tracking is still in progress.").font(.caption).foregroundStyle(.secondary)
                } else if !SpeakerDiarizer.supported {
                    Text("Speaker labels require macOS 15+. Plain transcription remains available.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Transcription model") {
                Picker("Release idle native models",selection:$m.settings.nativeModelRetention) { ForEach(NativeModelRetention.allCases,id:\.self) { Text($0.title) } }
                Text("Applies to native speech and speaker models. Active and queued work finishes first; the next use reloads released weights. Model files stay on disk. Shared Ollama models are managed separately.").font(.caption).foregroundStyle(.secondary)
                Picker("Speech engine",selection:$m.settings.speech.engine) { ForEach(SpeechEngine.allCases,id:\.self) { Text($0.title) } }
                if m.settings.speech.engine == .parakeet {
                    NativeModelDownloadView(setup:m.nativeModels,kind:.parakeet)
                    Picker("Compute",selection:$m.settings.speech.compute) { ForEach(SpeechCompute.allCases,id:\.self) { Text($0.title) } }
                    TextField("Parakeet v3 model directory",text:$m.settings.speech.modelDirectory)
                    Button("Choose native model directory…") {
                        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false
                        if panel.runModal() == .OK,let url=panel.url { m.settings.speech.modelDirectory=url.path }
                    }
                    Button("Release resident speech model") { Task { try? await m.audio.recognizer.unload() } }
                    Text("Uses local models only. Initial preparation can take time. Idle release follows your selection above; release manually after replacing files at the same path. Weights have separate publisher licenses.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("whisper.cpp executable",text:$m.settings.whisperBinary)
                    TextField("Whisper ggml model file",text:$m.settings.whisperModel)
                    Button("Choose model…") { let panel=NSOpenPanel(); if panel.runModal() == .OK,let url=panel.url { m.settings.whisperModel=url.path } }
                }
                TextField("Language (en, auto, fr…)",text:$m.settings.transcriptionLanguage)
            }
        }
    }
    private var connect: some View {
        Group {
            Section("Local API") {
                Toggle("Enable authenticated loopback API",isOn:Binding(get:{m.settings.apiEnabled},set:{if $0 { m.startAPI() } else { m.stopAPI() }}))
                Text(m.apiStatus).font(.caption)
                Text("Read only: GET /v1/search, /v1/memories/{id}, /v1/stats. Bound to 127.0.0.1:47831. Requests require Authorization: Bearer TOKEN. Browser origins are rejected.").font(.caption).foregroundStyle(.secondary)
                Button("Reveal token file") { NSWorkspace.shared.activateFileViewerSelecting([m.store.root.appendingPathComponent("api-token")]) }
            }
            Section("MCP for Claude, Cursor, Codex and other clients") {
                Text("Point your MCP client to oswindctl mcp. It provides search_memory, get_memory and memory_stats over stdio. The client runs locally with access to this user's OSwind store; configure only clients you trust.").font(.caption)
                Text(mcpConfiguration).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
            }
        }
    }
    private var data: some View {
        Group {
            Section("Your storage") {
                Text(m.store.root.path).font(.caption).textSelection(.enabled)
                Toggle("Automatic retention and storage cleanup",isOn:$m.settings.automaticMaintenance)
                Stepper("Retain \(m.settings.privacy.retentionDays) days",value:$m.settings.privacy.retentionDays,in:1...3650)
                Stepper("Storage budget: \(m.settings.privacy.maxStorageGB) GB",value:$m.settings.privacy.maxStorageGB,in:1...1000)
                Text("When enabled, cleanup runs every five minutes while the app is open and removes the oldest memories. Clean up now applies these limits explicitly. Restored libraries start with automatic cleanup off. Keep FileVault enabled for disk encryption.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Clean up now") { m.maintain() }; Button("Open data folder") { NSWorkspace.shared.open(m.store.root) } }
            }
            Section("Markdown & Obsidian") { MarkdownLibraryTransferView(transfer:m.libraryTransfer,store:m.store,policy:m.settings.privacy) }
            Section("Complete backup & restore") { LibraryTransferView(transfer:m.libraryTransfer,store:m.store) }
            Section("This library") {
                Text(m.store.root.path).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                LibrarySelectionButton(transfer:m.libraryTransfer)
                if ProcessInfo.processInfo.environment["OSWIND_DATA_DIR"] != nil { Text("Your launcher selects a library with OSWIND_DATA_DIR. It takes priority on the next launch.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Text interchange") {
                HStack { Button("Export text & metadata JSON") { m.exportData() }; Button("Import OSwind JSON") { m.importData() } }
                Text("JSON exchanges text, tags and metadata. Use a full backup for media and conversations. Imported JSON media paths are stripped and embeddings rebuilt; privacy exclusions and redaction apply.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Delete") { Button("Erase by time, app or website…") {showHistoryErasure=true}.disabled(m.libraryTransfer.busy); Button("Delete all local memories…",role:.destructive) { deleteConfirm = true } }
        }
    }
    private var mcpConfiguration: String {
        let object = ["mcpServers":["oswind":["command":"/Applications/OSwind.app/Contents/MacOS/oswindctl","args":["--data",m.store.root.path,"mcp"]]]] as [String:Any]
        return (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted])).flatMap { String(data:$0,encoding:.utf8) } ?? ""
    }
    private func entries(_ text: String) -> [String] { text.components(separatedBy:.newlines).map {$0.trimmingCharacters(in:.whitespaces)}.filter {!$0.isEmpty} }
    private func multiline(_ title: String,value: Binding<String>) -> some View { VStack(alignment:.leading,spacing:6) { Text(title).font(.caption); TextEditor(text:value).font(.system(size:11,design:.monospaced)).frame(height:68).padding(5).background(.background,in:RoundedRectangle(cornerRadius:6)) } }
    private func permissionRow(_ title: String,ready: Bool,detail: String,url: String) -> some View { HStack { Image(systemName:ready ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ready ? .green : .orange); VStack(alignment:.leading) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Open Settings") { NSWorkspace.shared.open(URL(string:url)!) } } }
}
struct OnboardingView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View { VStack(alignment:.leading,spacing:22) {
        Image(systemName:"wind").font(.system(size:54)).foregroundStyle(.mint)
        Text("A memory for your Mac.\nEntirely yours.").font(.system(size:34,weight:.medium,design:.rounded))
        Text("OSwind saves the windows you choose, reads their text on device, and helps you find your way back. Capture starts when you resume it.").foregroundStyle(.secondary)
        VStack(alignment:.leading,spacing:14) { Label("Local storage, no account, no telemetry",systemImage:"internaldrive"); Label("Pause anytime; exclude apps and websites",systemImage:"pause.circle"); Label("Local models or your own API keys",systemImage:"sparkles"); Label("Export and delete your memory",systemImage:"arrow.up.doc") }.font(.callout)
        Text("Screen Recording is required. Accessibility enables browser URL rules. Microphone and system audio are optional and controlled separately.").font(.caption).foregroundStyle(.secondary)
        HStack { Button("Explore first") { complete() }; Spacer(); Button("Set up OSwind") { complete(); m.showSettings = true }.buttonStyle(.borderedProminent) }
    }.padding(36).frame(width:590) }
    private func complete() { UserDefaults.standard.set(true,forKey:"onboarded"); dismiss() }
}
