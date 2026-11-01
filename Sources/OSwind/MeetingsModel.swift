import Foundation
import Combine
import AppKit
import CryptoKit
import OSwindCore

@MainActor final class MeetingsModel:ObservableObject {
    @Published private(set) var calendars=[MeetingCalendar]()
    @Published private(set) var events=[MeetingOccurrence]()
    @Published private(set) var due=[MeetingOccurrence]()
    @Published private(set) var access:MeetingCalendarAccess = .notRequested
    @Published private(set) var busy=false
    @Published private(set) var active=false
    @Published private(set) var status="Connect selected calendars to prepare for upcoming meetings."
    @Published private(set) var error:String?
    private let store:MemoryStore,provider:MeetingCalendarProvider,delivery:MeetingNotificationDelivery
    private let now:()->Date,locked:()->Bool,lowPower:()->Bool
    private let automaticPolling:Bool
    private var settings:AppSettings
    private var generation=UUID(),requestGeneration=UUID()
    private var requested=false,userPaused=false,pendingRefresh=false,notificationAttempted=false
    private var timer:Timer?
    private var loadTask:Task<Void,Never>?,selectionTask:Task<Void,Never>?,deliveryTask:Task<Void,Never>?
    private var rawEvents=[MeetingOccurrence](),loadedRevision:UInt64?,lastRead:Date?
    var allowed:()->Bool={true}
    var savePreferences:((MeetingContextConfiguration)throws->Void)?
    var prepareBrief:((MeetingOccurrence)->Void)?
    var openJoinURL:(URL)->Void={NSWorkspace.shared.open($0)}
    init(store:MemoryStore,settings:AppSettings,provider:MeetingCalendarProvider = .native(),delivery:MeetingNotificationDelivery = .native(),now:@escaping ()->Date={Date()},locked:@escaping ()->Bool={SessionState.locked},lowPower:@escaping ()->Bool={ProcessInfo.processInfo.isLowPowerModeEnabled},automaticPolling:Bool=true) {
        self.store=store;self.settings=settings;self.provider=provider;self.delivery=delivery;self.now=now;self.locked=locked;self.lowPower=lowPower;self.automaticPolling=automaticPolling
    }
    private func work<T:Sendable>(_ operation:@escaping @Sendable ()throws->T)async throws->T {
        let worker=Task.detached(priority:.utility,operation:operation)
        return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
    }
    var configuration:MeetingContextConfiguration {settings.meetings}
    var isPaused:Bool {userPaused}
    var pollingSeconds:TimeInterval {lowPower() ? 90:30}
    private var canUse:Bool {!store.isClosed && !locked() && allowed() && settings.privacy.exclusion(app:"com.apple.iCal",title:"",url:nil)==nil}
    private var prefix:String {"com.oswind.meeting."+(configuration.boundLibrary ?? "unbound")+"."+generation.uuidString.lowercased()+"."}
    func apply(_ value:AppSettings) {
        let changed=settings.meetings != value.meetings || settings.privacy != value.privacy
        let restart=requested && !userPaused,choices=calendars
        if changed {stop(clear:true,preserveRequest:true)}
        settings=value
        if changed,canUse {calendars=choices}
        if changed && restart && value.meetings.enabled {start()}
    }
    private func commit(_ configuration:MeetingContextConfiguration)throws {
        try configuration.validate()
        // The owner's callback persists first and may synchronously call apply.
        try savePreferences?(configuration)
        if settings.meetings != configuration {var value=settings;value.meetings=configuration;apply(value)}
    }
    func connect() {
        guard !busy,canUse else {status="Calendar is unavailable while locked, busy or excluded by Privacy.";return}
        selectionTask?.cancel();requestGeneration=UUID();let request=requestGeneration;busy=true;self.error=nil
        selectionTask=Task {[weak self] in
            guard let self else {return}
            defer {finishSelection(request)}
            do {
                let store=self.store;try await work {try store.validateDirectoryIdentity()}
                guard requestGeneration==request,!Task.isCancelled,canUse else {return}
                let access=try await provider.request()
                guard requestGeneration==request,!Task.isCancelled,canUse else {return};self.access=access
                guard access == .full else {calendars=[];status="Calendar needs read access. Review Calendar access in System Settings.";return}
                let list=try await provider.calendars()
                try await work {try store.validateDirectoryIdentity()}
                guard requestGeneration==request,!Task.isCancelled,canUse else {return}
                calendars=list;status="Choose calendars below. Only selected calendars are used."
            }catch is CancellationError {}catch {if requestGeneration==request {calendars=[];self.error="Calendar selection could not be loaded."}}
        }
    }
    private func finishSelection(_ request:UUID) {
        guard requestGeneration==request else {return};busy=false;selectionTask=nil
        if pendingRefresh {pendingRefresh=false;refresh(force:true)}
    }
    func select(_ calendar:MeetingCalendar,enabled:Bool) {
        guard !busy,canUse,calendars.contains(where:{$0.key==calendar.key}) else {return}
        var ids=configuration.calendarIDs.filter {Data($0.utf8) != Data(calendar.id.utf8)}
        if enabled {ids.append(calendar.id)}
        selectionTask?.cancel();requestGeneration=UUID();let request=requestGeneration;busy=true;self.error=nil
        selectionTask=Task {[weak self] in
            guard let self else {return};defer {finishSelection(request)}
            do {
                let store=self.store,id=try await work {try store.authorizeMeetingLibrary()}
                guard requestGeneration==request,!Task.isCancelled,canUse else {return}
                var c=configuration;c.calendarIDs=ids;c.enabled = !ids.isEmpty;c.boundLibrary=ids.isEmpty ? nil:id
                try commit(c)
                if c.enabled {userPaused=false;if !active {start()}}else {stop(clear:true);status="Calendar disconnected."}
            }catch {if requestGeneration==request {self.error="Calendar selection was not saved."}}
        }
    }
    func setReminderPreferences(enabled:Bool,lead:Int) {
        guard !busy,canUse,configuration.enabled else {return}
        selectionTask?.cancel();requestGeneration=UUID();let request=requestGeneration;busy=true;self.error=nil
        selectionTask=Task {[weak self] in
            guard let self else {return};defer {finishSelection(request)}
            do {
                if enabled {guard try await delivery.request() else {status="Notifications were not enabled. Meetings remain available here.";return}}
                guard requestGeneration==request,!Task.isCancelled,canUse else {return}
                var c=configuration;c.reminders=enabled;c.leadMinutes=lead;try commit(c)
            }catch {if requestGeneration==request {self.error="Meeting reminder preferences were not saved."}}
        }
    }
    func setParticipants(_ enabled:Bool) {
        guard !busy,canUse else {return}
        var c=configuration;c.includeParticipants=enabled
        do {try commit(c)}catch {self.error="Participant preference was not saved."}
    }
    func disconnect() {
        stop(clear:true)
        do {try commit(.init());status="Calendar disconnected."}catch {self.error="Calendar stopped, but its saved preference could not be updated."}
    }
    func start() {
        guard canUse else {sleep();return}
        guard configuration.enabled,!userPaused else {return}
        requested=true;active=true;self.error=nil;configureTimer();refresh(force:true)
    }
    func configureTimer() {
        timer?.invalidate();timer=nil
        guard automaticPolling,active else {return}
        timer=Timer.scheduledTimer(withTimeInterval:pollingSeconds,repeats:true) {[weak self] _ in Task {@MainActor in self?.refresh()}};timer?.tolerance=lowPower() ? 15:5
    }
    func pause() {userPaused=true;stop(clear:true,preserveRequest:true);status="Meeting context paused."}
    func resume() {userPaused=false;start()}
    func sleep() {stop(clear:true,preserveRequest:true)}
    func wake() {if requested && !userPaused {start()}}
    func stop(clear:Bool,preserveRequest:Bool=false) {
        // Clearing only the retired generation cannot remove a new generation's
        // notifications when asynchronous OS removal finishes late.
        let oldPrefix=prefix,clearNotifications=notificationAttempted;notificationAttempted=false;generation=UUID();requestGeneration=UUID();timer?.invalidate();timer=nil
        loadTask?.cancel();loadTask=nil;selectionTask?.cancel();selectionTask=nil;deliveryTask?.cancel();deliveryTask=nil;active=false;busy=false;pendingRefresh=false
        if !preserveRequest {requested=false}
        if clear {events=[];due=[];rawEvents=[];loadedRevision=nil;lastRead=nil;calendars=[];self.error=nil}
        if clearNotifications {let clear=delivery.clear;Task {await clear(oldPrefix)}}
    }
    func invalidate() {
        guard active else {return};events=[];due=[];lastRead=nil
        if busy || loadTask != nil {pendingRefresh=true}else {refresh(force:true)}
    }
    func refresh(force:Bool=false) {
        guard active else {return}
        guard canUse else {sleep();return}
        guard !busy,loadTask==nil else {if force {pendingRefresh=true};return}
        let token=generation,c=configuration,policy=settings.privacy,date=now(),source=provider,store=self.store
        let needsRead=force || loadedRevision != source.revision() || (lastRead.map {date.timeIntervalSince($0)>=300 || date<$0} ?? true)
        busy=true;self.error=nil
        loadTask=Task {[weak self] in
            guard let self else {return}
            defer {
                if generation==token {busy=false;loadTask=nil;if pendingRefresh {pendingRefresh=false;refresh(force:true)}}
            }
            do {
                let id=try await work {try store.meetingLibraryIdentity()}
                guard generation==token,!Task.isCancelled,canUse else {return}
                guard let id,c.admits(libraryIdentity:id) else {stop(clear:true);status="This library changed. Review and select calendars again.";return}
                let access=await source.access();guard generation==token,!Task.isCancelled,canUse else {return};self.access=access
                guard access == .full else {stop(clear:true);status="Calendar access was removed. Reconnect before refreshing.";return}
                if needsRead {
                    let feed=try await source.events(c.calendarIDs,c.includeParticipants,policy,date)
                    guard generation==token,!Task.isCancelled,canUse else {return}
                    guard source.revision()==feed.revision else {events=[];due=[];lastRead=nil;status="Calendar changed during refresh. Refresh again.";return}
                    rawEvents=feed.events;loadedRevision=feed.revision;lastRead=date
                }
                let currentLibrary=try await work {try store.meetingLibraryIdentity()}
                guard generation==token,!Task.isCancelled,canUse else {return}
                guard currentLibrary==id else {stop(clear:true);status="This library changed. Review and select calendars again.";return}
                guard source.revision()==loadedRevision else {events=[];due=[];lastRead=nil;status="Calendar changed during refresh. Refresh again.";return}
                let plan=try MeetingContextPlanner.make(events:rawEvents,configuration:c,libraryIdentity:id,policy:policy,now:now())
                guard generation==token,!Task.isCancelled,canUse else {return}
                events=plan.upcoming;due=plan.due;status=events.isEmpty ? "No upcoming meetings in the selected calendars.":"\(events.count) upcoming \(events.count==1 ? "meeting":"meetings") · selected calendars"
                if c.reminders && !plan.due.isEmpty,let revision=loadedRevision {notify(plan.due,configuration:c,library:id,date:date,token:token,revision:revision)}
            }catch is CancellationError {}catch {
                guard generation==token else {return};events=[];due=[];rawEvents=[];lastRead=nil;self.error="Meeting context could not refresh. Review Calendar access and the selection."
            }
        }
    }
    private func notify(_ events:[MeetingOccurrence],configuration:MeetingContextConfiguration,library:String,date:Date,token:UUID,revision:UInt64) {
        guard deliveryTask==nil else {return};let store=self.store,delivery=self.delivery,notificationPrefix=prefix,source=provider
        deliveryTask=Task {[weak self] in
            guard let self else {return};defer {if generation==token {deliveryTask=nil}}
            do {
                guard await delivery.allowed(),generation==token,!Task.isCancelled,canUse,source.revision()==revision else {return}
                var claims=[String]()
                for offset in stride(from:0,to:events.count,by:32) {
                    guard generation==token,!Task.isCancelled,canUse,source.revision()==revision else {return}
                    let group=Array(events[offset..<min(events.count,offset+32)])
                    do {claims += try await work {try store.claimMeetingReminders(group,configuration:configuration,expectedLibrary:library,now:date)}}
                    catch is CancellationError {throw CancellationError()}
                    catch {if claims.isEmpty {throw error};self.error="Some reminders could not be claimed. Review upcoming meetings here.";break}
                }
                guard generation==token,!Task.isCancelled,canUse,source.revision()==revision,!claims.isEmpty else {return}
                let currentLibrary=try await work {try store.meetingLibraryIdentity()}
                guard generation==token,!Task.isCancelled,canUse,source.revision()==revision else {return}
                guard currentLibrary==library else {stop(clear:true);status="This library changed. Review and select calendars again.";return}
                // One generic notification per refresh, even for a busy calendar.
                let digest=SHA256.hash(data:Data(claims.sorted().joined(separator:".").utf8)).map {String(format:"%02x",$0)}.joined()
                let id=notificationPrefix+digest
                notificationAttempted=true
                try await delivery.post(id)
                if generation != token || Task.isCancelled || !canUse || source.revision() != revision {await delivery.remove([id])}
            }catch is CancellationError {}catch {if generation==token {self.error="A meeting reminder could not be shown. Review upcoming meetings here."}}
        }
    }
    func reviewBrief(_ event:MeetingOccurrence) {verify(event) {[weak self] current in self?.prepareBrief?(current)}}
    func join(_ event:MeetingOccurrence) {verify(event) {[weak self] current in guard let url=current.joinURL,MeetingJoinLink.validate(url.absoluteString) != nil else {return};self?.openJoinURL(url)}}
    private func verify(_ event:MeetingOccurrence,action:@escaping (MeetingOccurrence)->Void) {
        guard active,canUse,!busy else {return}
        let token=generation,c=configuration,policy=settings.privacy,source=provider,date=now(),store=self.store
        selectionTask?.cancel();requestGeneration=UUID();let request=requestGeneration;busy=true
        selectionTask=Task {[weak self] in
            guard let self else {return};defer {finishSelection(request)}
            do {
                let id=try await work {try store.meetingLibraryIdentity()}
                let permission=await source.access()
                guard let id,generation==token,requestGeneration==request,!Task.isCancelled,canUse,c.admits(libraryIdentity:id),permission == .full else {throw CancellationError()}
                let feed=try await source.events(c.calendarIDs,c.includeParticipants,policy,date)
                guard generation==token,requestGeneration==request,!Task.isCancelled,canUse,source.revision()==feed.revision else {throw CancellationError()}
                let currentLibrary=try await work {try store.meetingLibraryIdentity()}
                guard generation==token,requestGeneration==request,!Task.isCancelled,canUse,currentLibrary==id,source.revision()==feed.revision else {throw CancellationError()}
                let plan=try MeetingContextPlanner.make(events:feed.events,configuration:c,libraryIdentity:id,policy:policy,now:now())
                guard let current=plan.upcoming.first(where:{$0.id==event.id}),current.revision==event.revision else {self.error="This meeting changed. Refresh before preparing or joining.";invalidate();return}
                action(current)
            }catch is CancellationError {}catch {if generation==token {self.error="This meeting is no longer available in the selected scope."}}
        }
    }
    deinit {timer?.invalidate();loadTask?.cancel();selectionTask?.cancel();deliveryTask?.cancel()}
}
