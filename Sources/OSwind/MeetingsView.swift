import SwiftUI
import OSwindCore

struct MeetingsView:View {
    @ObservedObject var model:MeetingsModel
    @EnvironmentObject var m:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text("Walk in with context.").font(.system(size:32,weight:.medium,design:.rounded))
                    Text("Upcoming meetings, connected to what you already know.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Calendar setup") {m.settingsTab="Connect";m.showSettings=true}
                if model.configuration.enabled {
                    Button(model.isPaused || !model.active ? "Resume":"Pause") {if model.active {model.pause()}else {model.resume()}}
                    Button {model.refresh(force:true)} label: {Label("Refresh",systemImage:"arrow.clockwise")}.disabled(model.busy || !model.active)
                }
            }
            HStack(spacing:10) {
                Image(systemName:"calendar.badge.clock").foregroundStyle(OSwindTheme.accent)
                Text(model.status).font(.callout)
                Spacer()
                if model.busy {ProgressView().controlSize(.small)}
            }.padding(14).background(OSwindTheme.accent.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
            if let error=model.error {Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.orange)}
            if model.events.isEmpty {
                ContentUnavailableView {
                    Label(model.configuration.enabled ? (model.active ? "Nothing coming up":"Meeting context paused"):"Your next meeting starts here",systemImage:"calendar")
                } description: {
                    Text(model.configuration.enabled ? "OSwind shows selected calendars for the next 36 hours. Refresh after calendar changes or review the selection in setup.":"Choose calendars in setup. Prepare a brief when you need one, then choose whether to open the meeting link.")
                } actions: {Button("Review calendar setup") {m.settingsTab="Connect";m.showSettings=true}}
                .frame(maxWidth:.infinity,maxHeight:.infinity)
            }else {
                Text("Times shown in \(TimeZone.current.identifier) · next 36 hours").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        ForEach(model.events) {event in MeetingOccurrenceCard(event:event,model:model)}
                    }.padding(.vertical,2)
                }
            }
            Text("Briefs search original recorded evidence from the last 30 days using your selected answer engine. Saved summaries are omitted. Evidence mode works without a model; local models and your configured API provider are available in Models. Joining opens a verified HTTPS link only when you click.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(30).onAppear {model.refresh()}
    }
}
private struct MeetingOccurrenceCard:View {
    let event:MeetingOccurrence
    @ObservedObject var model:MeetingsModel
    private var due:Bool {model.due.contains {$0.id==event.id}}
    var body:some View {
        HStack(alignment:.top,spacing:20) {
            VStack(alignment:.leading,spacing:5) {
                Text(event.start,format:.dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
                if event.allDay {Text("All day").font(.title3.weight(.medium))}else {Text(event.start,style:.time).font(.title3.weight(.medium));Text(event.end,style:.time).font(.caption).foregroundStyle(.secondary)}
            }.frame(width:110,alignment:.leading)
            VStack(alignment:.leading,spacing:9) {
                Text(event.title.isEmpty ? "Untitled meeting":event.title).font(.headline).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                if !event.participants.isEmpty {Label(event.participants.joined(separator:", "),systemImage:"person.2").font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                HStack(spacing:12) {
                    if due {Label("Starting soon",systemImage:"bell").foregroundStyle(OSwindTheme.accent)}
                    if let host=event.joinHost {Label(host,systemImage:"link").lineLimit(1)}
                    if let zone=event.timeZone,zone != TimeZone.current.identifier {Text("Event zone: "+zone).lineLimit(1)}
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            VStack(alignment:.trailing,spacing:10) {
                Button("Prepare brief") {model.reviewBrief(event)}.buttonStyle(.borderedProminent).disabled(model.busy || !model.active).help("Search recorded evidence from the last 30 days with your selected answer engine")
                if event.joinURL != nil {Button("Open meeting link") {model.join(event)}.disabled(model.busy || !model.active)}
            }
        }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).strokeBorder(OSwindTheme.accent.opacity(due ? 0.45:0.12)))
    }
}
struct MeetingReminderBanner:View {
    @ObservedObject var model:MeetingsModel
    var open:()->Void
    var body:some View {
        HStack(spacing:12) {
            Label(model.due.count==1 ? "A meeting is starting soon.":"\(model.due.count) meetings are starting soon.",systemImage:"bell")
            Spacer();Button("Review meetings",action:open)
        }.font(.callout).padding(.horizontal,24).padding(.vertical,12).background(OSwindTheme.accent.opacity(0.12))
    }
}
struct MeetingSettingsSections:View {
    @ObservedObject var model:MeetingsModel
    var body:some View {
        Section("Calendar & meeting context") {
            Text("Read selected calendars from Calendar on this Mac. OSwind does not edit events, invite participants or join automatically.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.calendars.isEmpty ? "Connect / choose calendars…":"Reload calendar selection") {model.connect()}.disabled(model.busy)
                if model.configuration.enabled {Button("Disconnect") {model.disconnect()}}
                if model.busy {ProgressView().controlSize(.small)}
            }
            if !model.calendars.isEmpty {
                ForEach(model.calendars,id:\.key) {calendar in
                    Toggle(isOn:Binding(get:{model.configuration.containsCalendar(calendar.id)},set:{model.select(calendar,enabled:$0)})) {
                        VStack(alignment:.leading,spacing:2) {Text(calendar.title.isEmpty ? "Untitled calendar":calendar.title);Text(calendar.account).font(.caption).foregroundStyle(.secondary)}
                    }.disabled(model.busy || (!model.configuration.containsCalendar(calendar.id) && model.configuration.calendarIDs.count>=32))
                }
                Text("Select up to 32 calendars.").font(.caption).foregroundStyle(.secondary)
            }else if model.configuration.enabled {Text("\(model.configuration.calendarIDs.count) calendars selected. Reload the selection to review their names.").font(.caption).foregroundStyle(.secondary)}
            Toggle("Include participant names in meeting context",isOn:Binding(get:{model.configuration.includeParticipants},set:{model.setParticipants($0)})).disabled(model.busy)
            Text("Names stay off by default; briefs include up to ten bounded names. Meeting notes, attendee email addresses and join links are omitted from brief requests. A brief uses your Models settings, including any explicit permission for remote context.").font(.caption).foregroundStyle(.secondary)
            Text(model.status).font(.caption)
            if let error=model.error {Label(error,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange)}
        }
        Section("Meeting reminders") {
            Toggle("Show generic desktop reminders",isOn:Binding(get:{model.configuration.reminders},set:{model.setReminderPreferences(enabled:$0,lead:model.configuration.leadMinutes)})).disabled(model.busy || !model.configuration.enabled)
            Picker("Remind me",selection:Binding(get:{model.configuration.leadMinutes},set:{model.setReminderPreferences(enabled:model.configuration.reminders,lead:$0)})) {
                ForEach([0,1,2,5,10,15,30],id:\.self) {lead in Text(lead==0 ? "At start time":"\(lead) minutes before").tag(lead)}
            }.disabled(model.busy || !model.configuration.enabled)
            Text("Notifications contain no meeting titles, participants or links. Delivery depends on macOS notification settings and Focus. OSwind records each attempt locally to avoid repeating it after restart; a crash may cause a missed reminder. Low Power Mode slows calendar checks to 90 seconds.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
