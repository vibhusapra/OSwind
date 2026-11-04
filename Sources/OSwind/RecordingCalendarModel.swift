import Foundation
import Combine
import OSwindCore

@MainActor final class RecordingCalendarModel:ObservableObject {
    @Published var presented=false
    @Published var date=Date()
    @Published var selectedID:String?
    @Published var recordingName=""
    @Published private(set) var events=[MeetingOccurrence]()
    @Published private(set) var loading=false
    @Published private(set) var saving=false
    @Published private(set) var loaded=false
    @Published private(set) var error:String?
    @Published private(set) var notice:String?
    var allowed:()->Bool={false}
    var refreshArchive:(()->Void)?
    private let store:MemoryStore,work:LibraryWorkRegistry,provider:MeetingCalendarProvider
    private var source:RecordedMeetingSource?,expected:RecordedMeetingDetailsSnapshot?,generation=UUID(),job:UUID?
    private struct Prepared:Sendable {let source:RecordedMeetingSource,selection:RecordedMeetingCalendarSelection,feed:MeetingFeed,range:DateInterval}
    private var prepared:Prepared?
    init(store:MemoryStore,work:LibraryWorkRegistry,provider:MeetingCalendarProvider = .native()) {self.store=store;self.work=work;self.provider=provider}
    var requiresName:Bool {expected==nil}
    var recordingTitle:String {expected?.name ?? source?.title ?? "Recording"}
    var hasReference:Bool {expected?.details.calendar != nil}
    var canSave:Bool {allowed() && loaded && !loading && !saving && events.contains(where:{$0.id==selectedID}) && prepared != nil && (!requiresName || (!recordingName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && recordingName.count<=200))}
    func title(_ event:MeetingOccurrence)->String {prepared?.selection.privacy.sanitize(event.title).text ?? "Calendar occurrence"}
    func calendarTitle(_ event:MeetingOccurrence)->String {
        guard let value=prepared else {return "Selected calendar"}
        if let calendar=value.feed.calendars.first(where:{Data($0.id.utf8)==Data(event.calendarID.utf8)}) {
            let title=value.selection.privacy.sanitize(calendar.title).text,account=value.selection.privacy.sanitize(calendar.account).text
            return account.isEmpty ? title:title+" · "+account
        }
        let index=value.selection.configuration.calendarIDs.firstIndex {Data($0.utf8)==Data(event.calendarID.utf8)} ?? 0
        return "Selected calendar \(index+1)"
    }
    func select(_ source:RecordedMeetingSource?,expected:RecordedMeetingDetailsSnapshot?) {
        guard let source else {clear();return}
        if let previous=self.source,previous.sessionKey != source.sessionKey || !previous.isFromSameOpenLibrary(as:source) {clear()}
        if self.source?.sessionKey==source.sessionKey,self.expected==expected {
            self.source=source
            if presented,!loaded,!loading,!saving {load()};return
        }
        if self.source != source || self.expected != expected {invalidate();self.source=source;self.expected=expected}
        if presented,!loaded,!loading {load()}
    }
    func invalidate() {
        generation=UUID();if let job {work.cancel(id:job)};job=nil
        events=[];selectedID=nil;prepared=nil;loaded=false;loading=false;saving=false;error=nil
    }
    func clear() {invalidate();source=nil;expected=nil;presented=false;notice=nil;date=Date();recordingName=""}
    func open() {
        guard allowed(),let source,!saving else {return}
        date=expected?.details.calendar?.start ?? source.timestamp;if requiresName && recordingName.isEmpty {recordingName=String(source.title.prefix(200))};presented=true;notice=nil;load()
    }
    func dismiss() {guard !saving else {return};invalidate();presented=false;recordingName=""}
    nonisolated private static func admit(_ provider:MeetingCalendarProvider,revision:UInt64)throws {
        try Task.checkCancellation()
        guard provider.accessNow() == .full,provider.revision()==revision else {throw OSwindError.unavailable("Calendar access or its contents changed. Reload occurrences before saving.")}
    }
    nonisolated private static func visible(_ feed:MeetingFeed,selection:RecordedMeetingCalendarSelection)throws->[MeetingOccurrence] {
        guard feed.events.count<=1000,Set(feed.events.map(\.id)).count==feed.events.count else {throw OSwindError.unavailable("Calendar returned too many or duplicate occurrences. Choose a smaller window.")}
        return feed.events.filter {!$0.cancelled && !$0.declined && selection.configuration.containsCalendar($0.calendarID) && selection.privacy.exclusion(app:"com.apple.iCal",title:$0.title,url:$0.joinURL?.absoluteString)==nil}.sorted {$0.start==$1.start ? $0.id<$1.id:$0.start<$1.start}
    }
    func load() {
        guard presented,allowed(),!saving,let source else {return}
        invalidate()
        guard date.timeIntervalSinceReferenceDate.isFinite else {error="Choose a valid calendar date.";return}
        let token=generation,store=store,provider=provider,expected=self.expected,day=Calendar.current.startOfDay(for:date)
        guard let end=Calendar.current.date(byAdding:.day,value:1,to:day),day.timeIntervalSinceReferenceDate.isFinite else {error="Choose a valid calendar date.";return}
        let range=DateInterval(start:day,end:end);loading=true
        job=work.launch(kind:.recordedMeetings,operation:{
            let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
            let selection=try store.recordedMeetingCalendarSelection(for:source,replacing:expected)
            guard provider.accessNow() == .full,await provider.access() == .full else {throw OSwindError.unavailable("Calendar read access is unavailable. Review access in Upcoming or System Settings.")}
            let feed=try await provider.eventsInRange(selection.configuration.calendarIDs,selection.privacy,range)
            try Self.admit(provider,revision:feed.revision)
            _=try Self.visible(feed,selection:selection)
            return try store.withCurrentRecordedMeetingCalendarSelection(selection,settingsSnapshot:snapshot) {Prepared(source:source,selection:selection,feed:feed,range:range)}
        }) {[weak self] result,cancelled in
            guard let self,self.generation==token else {return};self.job=nil;self.loading=false
            guard !cancelled,self.presented,self.allowed() else {return}
            do {
                let value=try result.get();try Self.admit(provider,revision:value.feed.revision)
                try store.withCurrentRecordedMeetingCalendarSelection(value.selection) {
                    self.prepared=value;self.events=try Self.visible(value.feed,selection:value.selection);self.loaded=true
                    if let link=expected?.details.calendar,self.events.contains(where:{link.matches($0,libraryIdentity:value.selection.libraryIdentity)}) {self.selectedID=link.occurrenceID}
                }
            }catch {self.fail(error)}
        }
        if job==nil {loading=false;error="The library is closing. Reopen the recording to review Calendar."}
    }
    func useEventTitle() {if requiresName,let event=events.first(where:{$0.id==selectedID}),!saving {recordingName=String(title(event).prefix(200))}}
    func recheckRecording() {
        guard presented,!saving,let prepared else {return}
        do {try store.withCurrentRecordedMeetingCalendarSelection(prepared.selection) {}}
        catch RecordedMeetingRefreshError.busy {return}
        catch {invalidate();self.error="The recording, saved name or privacy settings changed. Reload occurrences to review again."}
    }
    func checkForChanges() {
        guard presented,!saving,let prepared else {return}
        if provider.accessNow() != .full || provider.revision() != prepared.feed.revision {
            invalidate();error="Calendar access or its contents changed. Reload occurrences before saving."
        }else {recheckRecording()}
    }
    func save() {
        guard canSave,let value=prepared,let selected=events.first(where:{$0.id==selectedID}),source != nil else {return}
        write(source:value.source,expected:expected,value:value,event:selected)
    }
    func unlink() {
        guard allowed(),!saving,let source,let expected,expected.details.calendar != nil else {return}
        write(source:source,expected:expected,value:nil,event:nil)
    }
    private func write(source:RecordedMeetingSource,expected:RecordedMeetingDetailsSnapshot?,value:Prepared?,event:MeetingOccurrence?) {
        invalidate();let token=generation,store=store,provider=provider,draft=expected==nil ? recordingName:nil;saving=true
        job=work.launch(kind:.recordedMeetings,operation:{
            if let value,let event {
                let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
                try Self.admit(provider,revision:value.feed.revision)
                let fresh=try store.recordedMeetingCalendarSelection(for:source,replacing:expected)
                guard fresh==value.selection else {throw RecordedMeetingRefreshError.changed}
                let feed=try await provider.eventsInRange(fresh.configuration.calendarIDs,fresh.privacy,value.range)
                try Self.admit(provider,revision:feed.revision)
                let matches=try Self.visible(feed,selection:fresh).filter {$0.id==event.id && $0.revision==event.revision}
                guard matches.count==1,let current=matches.first else {throw OSwindError.unavailable("The chosen occurrence changed or is unavailable. Reload Calendar before saving.")}
                let link=try RecordingCalendarLink(event:current,libraryIdentity:fresh.libraryIdentity)
                return try store.setRecordedMeetingCalendar(link,for:source,replacing:expected,recordingName:draft,selection:fresh,settingsSnapshot:snapshot,admit:{try Self.admit(provider,revision:feed.revision)})
            }
            return try store.setRecordedMeetingCalendar(nil,for:source,replacing:expected,admit:{})
        }) {[weak self] result,cancelled in
            guard let self,self.generation==token else {return};self.job=nil;self.saving=false
            guard !cancelled,self.allowed() else {return}
            do {
                let saved=try result.get();self.expected=saved;self.presented=false;self.notice=event==nil ? "Calendar link removed.":"Calendar link saved. Original recording content is unchanged."
                self.refreshArchive?()
            }catch {self.fail(error)}
        }
        if job==nil {saving=false;error="The library is closing. No calendar change was submitted."}
    }
    private func fail(_ value:Error) {
        events=[];selectedID=nil;prepared=nil;loaded=false
        if case OSwindError.unavailable(let message)=value {error=message}
        else if case OSwindError.invalid(let message)=value {error=message}
        else {error="The recording, saved name or Calendar changed. Reload occurrences and review the selection."}
    }
}
