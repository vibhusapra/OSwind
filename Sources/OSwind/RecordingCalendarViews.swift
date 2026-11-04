import SwiftUI
import OSwindCore

struct RecordingCalendarSection:View {
    @ObservedObject var calendar:RecordingCalendarModel
    @ObservedObject var names:RecordingNamesModel
    @ObservedObject var archive:RecordedMeetingsModel
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Label(calendar.hasReference ? "Linked calendar event":"Optional calendar link",systemImage:"calendar").foregroundStyle(.secondary)
                Spacer()
                Button(calendar.hasReference ? "Review calendar":"Link calendar") {calendar.open()}.disabled(!names.canEdit || archive.busy)
                if calendar.hasReference {Button("Remove link",role:.destructive) {calendar.unlink()}.disabled(!names.canEdit || archive.busy)}
                if calendar.saving {ProgressView().controlSize(.small)}
            }.font(.caption)
            if let notice=calendar.notice {Text(notice).font(.caption).foregroundStyle(.secondary)}
            if !calendar.presented,let error=calendar.error {Label {Text(error)} icon:{Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)}.font(.caption)}
        }
        .sheet(isPresented:$calendar.presented,onDismiss:{calendar.dismiss()}) {RecordingCalendarPickerView(calendar:calendar)}
    }
}
struct RecordingCalendarPickerView:View {
    @ObservedObject var calendar:RecordingCalendarModel
    private func accessibilityTitle(_ event:MeetingOccurrence)->String {
        let stamp=event.start.formatted(date:.abbreviated,time:.shortened)
        return calendar.title(event)+", "+calendar.calendarTitle(event)+", "+stamp
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Link a calendar event").font(.title2.weight(.semibold))
            Text("Choose the event from your selected calendars. Your clips, transcripts and calendar events stay unchanged.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if calendar.requiresName {
                TextField("Recording name",text:$calendar.recordingName).textFieldStyle(.roundedBorder).disabled(calendar.saving)
                HStack {Text("\(calendar.recordingName.count)/200 characters").foregroundStyle(.secondary);Spacer();Button("Use selected event’s title") {calendar.useEventTitle()}.disabled(calendar.selectedID==nil || calendar.saving)}.font(.caption)
            }else {Text(calendar.recordingTitle).font(.headline).lineLimit(2)}
            HStack {
                DatePicker("On date",selection:$calendar.date,displayedComponents:.date).disabled(calendar.saving)
                Button("Reload") {calendar.load()}.disabled(calendar.loading || calendar.saving)
            }
            if calendar.loading {HStack {ProgressView().controlSize(.small);Text("Reading selected calendars…").font(.callout)}}
            if let error=calendar.error {Label {Text(error)} icon:{Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)}.font(.callout).fixedSize(horizontal:false,vertical:true)}
            if calendar.loaded,calendar.events.isEmpty {Text("No permitted occurrences on this date. Choose another date, or review your selected calendars in Upcoming.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if !calendar.events.isEmpty {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(calendar.events) {event in
                            Button {calendar.selectedID=event.id} label: {
                                HStack(alignment:.top,spacing:10) {
                                    Image(systemName:calendar.selectedID==event.id ? "checkmark.circle.fill":"circle").foregroundStyle(calendar.selectedID==event.id ? OSwindTheme.accent:Color.secondary)
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(calendar.title(event)).font(.headline).lineLimit(2)
                                        Text(calendar.calendarTitle(event)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if event.allDay {Text("All day").font(.caption).foregroundStyle(.secondary)}else {Text(event.start,format:.dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)}
                                    };Spacer(minLength:0)
                                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(calendar.selectedID==event.id ? OSwindTheme.accent.opacity(0.1):Color.clear,in:RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).disabled(calendar.saving).help(calendar.calendarTitle(event)).accessibilityLabel(accessibilityTitle(event)).accessibilityAddTraits(calendar.selectedID==event.id ? .isSelected:[])
                        }
                    }
                }.frame(minHeight:100,maxHeight:280)
            }
            HStack {
                if calendar.saving {ProgressView().controlSize(.small);Text("Linking event…").font(.caption)}
                Spacer()
                Button("Cancel") {calendar.dismiss()}.keyboardShortcut(.cancelAction).disabled(calendar.saving)
                Button("Link event") {calendar.save()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!calendar.canSave)
            }
        }.padding(24).frame(width:520)
        .interactiveDismissDisabled(calendar.saving)
        .onChange(of:calendar.date) {_,_ in if !calendar.saving {calendar.load()}}
        .task {while !Task.isCancelled {do {try await Task.sleep(for:.seconds(3))}catch {return};calendar.checkForChanges()}}
    }
}
