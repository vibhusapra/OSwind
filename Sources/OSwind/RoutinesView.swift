import SwiftUI
import OSwindCore

private struct RoutineEditorSelection:Identifiable {var value:RoutineDefinition;var revision:Int?;var id:String {value.id}}

struct RoutinesView:View {
    @EnvironmentObject var app:AppModel
    @ObservedObject var model:RoutinesModel
    @State private var editing:RoutineEditorSelection?
    @State private var deleting:StoredRoutine?
    private func nextTime(_ routine:StoredRoutine) -> String {
        let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .short;formatter.timeZone=TimeZone(identifier:routine.definition.schedule.timeZone)
        return formatter.string(from:routine.nextDue)
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:7) {Text("Make room for reflection.").font(.system(size:32,weight:.medium,design:.rounded));Text("Recaps, standups and action lists, grounded in your recorded day.").foregroundStyle(.secondary)}
                    Spacer();Button("New routine",systemImage:"plus") {var d=RoutineDefinition();d.ai=app.settings.ai;editing=RoutineEditorSelection(value:d,revision:nil)}.buttonStyle(.borderedProminent)
                }
                VStack(alignment:.leading,spacing:10) {
                    Toggle("Run schedules while OSwind is open",isOn:Binding(get:{app.settings.routinesEnabled},set:{app.configureRoutineScheduling($0)})).accessibilityIdentifier("routines-enabled")
                    if app.settings.routinesEnabled && !model.schedulingActive {
                        Text("Schedules are paused for this library. Resume schedules to check due routines without starting capture or the API.").font(.caption).foregroundStyle(.secondary)
                        Button("Resume schedules") {app.configureRoutineScheduling(true)}.disabled(app.showOnboarding || app.libraryWipe.busy || app.libraryWipe.pendingCleanup || app.demo)
                    }
                    Text("Runs one routine at a time. After sleep or restart, only the latest missed occurrence can run, within 24 hours. OSwind does not wake your Mac. Failed or interrupted occurrences wait for a manual retry.").font(.caption).foregroundStyle(.secondary)
                    if model.busy {HStack {ProgressView().controlSize(.small);Text("Preparing a source-linked result…").font(.caption);Spacer();Button("Cancel run"){model.cancel()}}}
                }.padding(18).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:12))
                if let error=model.error {Label(error,systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)}
                if model.items.isEmpty {
                    ContentUnavailableView("A little perspective, on schedule",systemImage:"calendar.badge.clock",description:Text("Choose a prompt, a source window and a time. Results stay in your conversation history with their original evidence."))
                }
                ForEach(model.items) {routine in
                    VStack(alignment:.leading,spacing:12) {
                        HStack {Text(routine.definition.title).font(.title3.weight(.medium));Spacer();Text(routine.definition.enabled ? "Enabled":"Paused").font(.caption).foregroundStyle(.secondary)}
                        Text(routine.definition.prompt).foregroundStyle(.secondary).lineLimit(3)
                        HStack(spacing:16) {
                            Label(routine.definition.window.title,systemImage:"clock")
                            Text(routine.definition.ai.provider.label)
                        }.font(.caption).foregroundStyle(.secondary)
                        Text("Next: \(nextTime(routine)) · \(routine.definition.schedule.timeZone)").font(.caption).foregroundStyle(.secondary)
                        HStack {Button("Run now"){model.runNow(routine.id)}.disabled(model.busy);Button("Edit"){editing=RoutineEditorSelection(value:routine.definition,revision:routine.revision)};Button(routine.definition.enabled ? "Pause":"Enable"){model.toggle(routine)};Spacer();Button("Delete",role:.destructive){deleting=routine}}
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.08)))
                }
                if !model.history.isEmpty {
                    Text("Recent runs").font(.title2.weight(.medium))
                    ForEach(model.history.prefix(30)) {run in
                        HStack(alignment:.top,spacing:12) {
                            Image(systemName:run.status == .completed ? "checkmark.circle":"clock").foregroundStyle(.secondary)
                            VStack(alignment:.leading,spacing:4) {
                                Text(model.items.first(where:{$0.id==run.routineID})?.definition.title ?? "Routine").font(.callout.weight(.medium))
                                Text("\(run.trigger.rawValue.capitalized) · \(run.scheduledAt.formatted(date:.abbreviated,time:.shortened)) · \(run.status.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
                                if let message=run.message {Text(message).font(.caption).foregroundStyle(.secondary)}
                                if run.status == .completed && !run.resultAvailable {Text("Result removed with its conversation or source evidence.").font(.caption).foregroundStyle(.secondary)}
                            };Spacer()
                            if run.resultAvailable,let id=run.chatID {Button("Open result"){app.section="Ask";app.selectChat(id)}}
                        }.padding(.vertical,10)
                        Divider()
                    }
                }
            }.padding(30).frame(maxWidth:1100,alignment:.leading).frame(maxWidth:.infinity)
        }
        .task {model.reload()}
        .sheet(item:$editing) {value in RoutineEditor(value:value.value,revision:value.revision,model:model)}
        .confirmationDialog("Delete this routine and its saved result conversations?",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}}),titleVisibility:.visible) {Button("Delete routine and results",role:.destructive){if let deleting {model.delete(deleting.id)};deleting=nil};Button("Cancel",role:.cancel){deleting=nil}}
    }
}
struct RoutineEditor:View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app:AppModel
    @ObservedObject var model:RoutinesModel
    @State private var value:RoutineDefinition
    let revision:Int?
    init(value:RoutineDefinition,revision:Int?,model:RoutinesModel){self._value=State(initialValue:value);self.revision=revision;self.model=model}
    private let days=[(1,"Sun"),(2,"Mon"),(3,"Tue"),(4,"Wed"),(5,"Thu"),(6,"Fri"),(7,"Sat")]
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(revision==nil ? "A routine for your day":"Edit routine").font(.title2.weight(.medium))
            Form {
                TextField("Name",text:$value.title)
                HStack {
                    Button("Day recap"){value.title="Day recap";value.prompt="Summarize recorded work, decisions and action items. Cite evidence; mark missing details.";value.window = .today}
                    Button("Standup"){value.title="Morning standup";value.prompt="Draft a standup: completed work, in progress and blockers. Use only recorded evidence; cite sources.";value.window = .yesterday;value.schedule.hour=9;value.schedule.weekdays=[2,3,4,5,6]}
                    Button("Action items"){value.title="Action review";value.prompt="Extract action items, owners and deadlines explicitly stated in the recorded evidence. Mark missing details and cite sources."}
                }.buttonStyle(.bordered)
                TextEditor(text:$value.prompt).font(.body).frame(height:100).accessibilityLabel("Routine prompt")
                Picker("Source window",selection:$value.window){ForEach(RoutineWindow.allCases,id:\.self){Text($0.title)}}
                TextField("Application (blank for all)",text:Binding(get:{value.app ?? ""},set:{value.app=$0.isEmpty ? nil:$0}))
                TextField("Tag (blank for all)",text:Binding(get:{value.tag ?? ""},set:{value.tag=$0.isEmpty ? nil:$0}))
                Picker("Source kind",selection:Binding(get:{value.kind?.rawValue ?? "all"},set:{value.kind=MemoryKind(rawValue:$0)})){Text("All kinds").tag("all");ForEach(MemoryKind.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0.rawValue)}}
                Picker("Cadence",selection:$value.schedule.cadence){Text("Time and weekdays").tag(RoutineCadence.calendar);Text("Every interval").tag(RoutineCadence.interval)}
                if value.schedule.cadence == .interval {
                    TextField("Interval in minutes (1–10080)",value:$value.schedule.intervalMinutes,format:.number).accessibilityIdentifier("routine-interval-minutes")
                    Text("Intervals use fixed elapsed-minute boundaries. Missed intervals coalesce to the latest one.").font(.caption).foregroundStyle(.secondary)
                } else {
                HStack {Stepper("Hour \(value.schedule.hour)",value:$value.schedule.hour,in:0...23);Stepper("Minute \(String(format:"%02d",value.schedule.minute))",value:$value.schedule.minute,in:0...59)}
                HStack {ForEach(days,id:\.0){day in Toggle(day.1,isOn:Binding(get:{value.schedule.weekdays.contains(day.0)},set:{on in if on {if !value.schedule.weekdays.contains(day.0){value.schedule.weekdays.append(day.0)}} else {value.schedule.weekdays.removeAll{$0==day.0}}})).toggleStyle(.button)}}
                }
                Picker("Time zone",selection:$value.schedule.timeZone){ForEach(TimeZone.knownTimeZoneIdentifiers,id:\.self){Text($0).tag($0)}}
                Toggle("Enable this schedule",isOn:$value.enabled)
                HStack {Text(value.ai.provider.label).font(.callout);Spacer();Button("Use current model settings"){value.ai=app.settings.ai}}
                Text("Model: \(value.ai.model). The provider and model are saved with this routine.").font(.caption).foregroundStyle(.secondary)
                Toggle("Allow selected context to a remote provider",isOn:$value.allowRemote)
                Text("Remote runs also require permission in Models settings. Local providers need no remote permission. Results and citations are saved on this Mac.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let error=model.error {Text(error).font(.caption).foregroundStyle(.secondary)}
            HStack {Button("Cancel"){dismiss()};Spacer();Button("Save routine"){if model.save(value,revision:revision){dismiss()}}.buttonStyle(.borderedProminent)}
        }.padding(24).frame(width:720,height:800)
    }
}
