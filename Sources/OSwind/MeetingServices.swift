import Foundation
import EventKit
import UserNotifications
import OSwindCore

enum MeetingCalendarAccess:Equatable,Sendable {case notRequested,full,writeOnly,denied,restricted,unknown}
struct MeetingFeed:Sendable {let events:[MeetingOccurrence];let revision:UInt64}
struct MeetingCalendarProvider:Sendable {
    var access:@Sendable () async ->MeetingCalendarAccess
    var request:@Sendable () async throws ->MeetingCalendarAccess
    var calendars:@Sendable () async throws ->[MeetingCalendar]
    var events:@Sendable ([String],Bool,PrivacyPolicy,Date) async throws ->MeetingFeed
    var revision:@Sendable ()->UInt64
    static func native()->Self {
        let source=EventKitMeetingSource()
        return .init(access:{await source.access()},request:{try await source.request()},calendars:{try await source.calendars()},events:{try await source.events(ids:$0,participants:$1,policy:$2,now:$3)},revision:{source.clock.read()})
    }
}
private final class MeetingStoreRevision:@unchecked Sendable {
    private let lock=NSLock()
    private var value:UInt64=0
    private var token:NSObjectProtocol?
    init() {token=NotificationCenter.default.addObserver(forName:.EKEventStoreChanged,object:nil,queue:nil) {[weak self] _ in self?.advance()}}
    func read()->UInt64 {lock.lock();defer {lock.unlock()};return value}
    private func advance() {lock.lock();value &+= 1;lock.unlock()}
    deinit {if let token {NotificationCenter.default.removeObserver(token)}}
}
private actor EventKitMeetingSource {
    nonisolated let clock=MeetingStoreRevision()
    private var store:EKEventStore?
    private func instance()->EKEventStore {if let store {return store};let value=EKEventStore();store=value;return value}
    func access()->MeetingCalendarAccess {
        switch EKEventStore.authorizationStatus(for:.event) {
        case .notDetermined:return .notRequested
        case .fullAccess:return .full
        case .writeOnly:return .writeOnly
        case .denied:return .denied
        case .restricted:return .restricted
        @unknown default:return .unknown
        }
    }
    func request()async throws->MeetingCalendarAccess {
        if access() == .notRequested {
            guard Bundle.main.object(forInfoDictionaryKey:"NSCalendarsFullAccessUsageDescription") as? String != nil else {throw OSwindError.unavailable("Use the packaged OSwind app to connect Calendar.")}
            let allowed:Bool=try await withCheckedThrowingContinuation {continuation in
                instance().requestFullAccessToEvents {allowed,error in
                    if let error {continuation.resume(throwing:error)}else {continuation.resume(returning:allowed)}
                }
            }
            guard allowed else {return access()}
        }
        try Task.checkCancellation();return access()
    }
    func calendars()throws->[MeetingCalendar] {
        guard access() == .full else {throw OSwindError.unavailable("Calendar read access is unavailable. Review Calendar access in System Settings.")}
        let store=instance();store.reset();let values=store.calendars(for:.event)
        guard values.count<=128 else {throw OSwindError.unavailable("Too many calendars are available for a bounded selection.")}
        return try values.map {try MeetingCalendar(id:$0.calendarIdentifier,title:$0.title,account:$0.source.title)}.sorted {$0.title.localizedStandardCompare($1.title) == .orderedAscending}
    }
    func events(ids:[String],participants:Bool,policy:PrivacyPolicy,now:Date)throws->MeetingFeed {
        guard access() == .full else {throw OSwindError.unavailable("Calendar read access was removed. Reconnect Calendar before refreshing.")}
        guard policy.exclusion(app:"com.apple.iCal",title:"",url:nil)==nil,!ids.isEmpty,ids.count<=32,now.timeIntervalSinceReferenceDate.isFinite else {throw OSwindError.unavailable("Select permitted calendars before reading meeting context.")}
        try Task.checkCancellation();let before=clock.read(),store=instance();store.reset()
        let keys=Set(ids.map {Data($0.utf8)}),available=store.calendars(for:.event)
        guard available.count<=128 else {throw OSwindError.unavailable("Too many calendars are available for a bounded selection.")}
        let selected=available.filter {keys.contains(Data($0.calendarIdentifier.utf8))}
        guard selected.count==keys.count else {throw OSwindError.unavailable("A selected calendar is no longer available. Review the selection.")}
        let predicate=store.predicateForEvents(withStart:now.addingTimeInterval(-1800),end:now.addingTimeInterval(36*3600),calendars:selected)
        var result=[MeetingOccurrence](),failure:Error?,count=0
        store.enumerateEvents(matching:predicate) {event,stop in
            count+=1
            if Task.isCancelled {failure=CancellationError();stop.pointee=true;return}
            guard count<=1000 else {failure=OSwindError.unavailable("This calendar window exceeds 1,000 occurrences. Select fewer calendars.");stop.pointee=true;return}
            let title=event.title ?? "Untitled meeting"
            guard title.utf8.prefix(1201).count<=1200 else {failure=OSwindError.unavailable("A meeting title exceeds the context bound.");stop.pointee=true;return}
            let eventURL=event.url?.absoluteString
            guard (eventURL?.utf8.prefix(4097).count ?? 0)<=4096 else {failure=OSwindError.unavailable("A meeting URL exceeds the context bound.");stop.pointee=true;return}
            guard policy.exclusion(app:"com.apple.iCal",title:title,url:eventURL)==nil else {return}
            let link=MeetingJoinLink.first(in:[eventURL ?? "",event.location ?? "",event.notes ?? ""])
            guard policy.exclusion(app:"com.apple.iCal",title:title,url:link?.absoluteString)==nil else {return}
            do {
                let start:Date?=event.startDate,end:Date?=event.endDate,calendar:EKCalendar?=event.calendar
                guard let start,let end,let calendar,keys.contains(Data(calendar.calendarIdentifier.utf8)) else {throw OSwindError.unavailable("Calendar data changed during this refresh.")}
                let external:String?=event.calendarItemExternalIdentifier,local=event.calendarItemIdentifier
                let series=(external?.isEmpty==false ? external:nil) ?? local
                let attendees=event.attendees ?? []
                guard attendees.count<=256 else {throw OSwindError.unavailable("A meeting exceeds the participant bound.")}
                let declined=attendees.contains {$0.isCurrentUser && $0.participantStatus == .declined}
                let names=participants ? attendees.prefix(20).compactMap(\.name).map {policy.sanitize(String($0.unicodeScalars.prefix(160))).text}:[]
                let occurrence=try MeetingOccurrence(calendarID:calendar.calendarIdentifier,seriesID:series,originalOccurrence:event.occurrenceDate,start:start,end:end,title:policy.sanitize(title).text,participants:names,joinURL:link,allDay:event.isAllDay,cancelled:event.status == .canceled,declined:declined,timeZone:event.timeZone?.identifier)
                result.append(occurrence)
            }catch {failure=error;stop.pointee=true}
        }
        if let failure {throw failure};try Task.checkCancellation()
        guard access() == .full,before==clock.read() else {throw OSwindError.unavailable("Calendar changed during refresh. Refresh again before preparing or joining.")}
        return .init(events:result,revision:before)
    }
}

struct MeetingNotificationDelivery:Sendable {
    var allowed:@Sendable () async ->Bool
    var request:@Sendable () async throws ->Bool
    var post:@Sendable (String) async throws ->Void
    var remove:@Sendable ([String]) async ->Void
    var clear:@Sendable (String) async ->Void
    private static var supported:Bool {Bundle.main.bundleIdentifier?.isEmpty==false}
    static func native()->Self {
        .init(allowed:{guard Self.supported else {return false};return await withCheckedContinuation {continuation in UNUserNotificationCenter.current().getNotificationSettings {settings in continuation.resume(returning:settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)}}},request:{guard Self.supported else {throw OSwindError.unavailable("Use the packaged OSwind app to enable desktop reminders.")};return try await withCheckedThrowingContinuation {continuation in UNUserNotificationCenter.current().requestAuthorization(options:[.alert]) {allowed,error in if let error {continuation.resume(throwing:error)}else {continuation.resume(returning:allowed)}}}},post:{identifier in
            guard Self.supported else {throw OSwindError.unavailable("Desktop reminders need the packaged OSwind app.")}
            let content=UNMutableNotificationContent();content.title="Upcoming meeting";content.body="Open OSwind to review your meetings and choose whether to join."
            // Generic text only: no event title, participant, calendar, link or
            // secret is placed on the lock screen or in notification userInfo.
            let request=UNNotificationRequest(identifier:identifier,content:content,trigger:nil)
            try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in UNUserNotificationCenter.current().add(request) {error in if let error {continuation.resume(throwing:error)}else {continuation.resume(returning:())}}}
        },remove:{ids in
            guard Self.supported else {return}
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:ids);UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:ids)
        },clear:{prefix in
            guard Self.supported else {return}
            let center=UNUserNotificationCenter.current()
            let pending:[String]=await withCheckedContinuation {continuation in center.getPendingNotificationRequests {continuation.resume(returning:$0.map(\.identifier).filter {$0.hasPrefix(prefix)})}}
            let delivered:[String]=await withCheckedContinuation {continuation in center.getDeliveredNotifications {continuation.resume(returning:$0.map { $0.request.identifier }.filter {$0.hasPrefix(prefix)})}}
            center.removePendingNotificationRequests(withIdentifiers:pending);center.removeDeliveredNotifications(withIdentifiers:delivered)
        })
    }
}
