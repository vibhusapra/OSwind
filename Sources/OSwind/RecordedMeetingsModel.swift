import Foundation
import Combine
import OSwindCore

@MainActor final class RecordedMeetingsModel:ObservableObject {
    @Published private(set) var sessions=[RecordedMeeting]()
    @Published private(set) var busy=false
    @Published private(set) var error:String?
    @Published private(set) var status="Record a meeting or import audio to keep its sources together."
    @Published private(set) var hasOlder=false
    @Published var selectedID:String?
    var allowed:()->Bool={false}
    var beginChat:((RecordedMeetingSource,Bool)->Void)?
    var openSource:((RecordedMeetingSource)->Void)?
    private let store:MemoryStore,work:LibraryWorkRegistry
    private let readPage:@Sendable (MemoryStore,RecordedMeetingCursor?)throws->RecordedMeetingPage
    private var sources=[String:RecordedMeetingSource](),cursor:RecordedMeetingCursor?,job:UUID?,generation=UUID(),visible=false,appearance:UUID?
    init(store:MemoryStore,work:LibraryWorkRegistry,readPage:@escaping @Sendable (MemoryStore,RecordedMeetingCursor?)throws->RecordedMeetingPage = {try $0.recordedMeetingPage(before:$1)}) {self.store=store;self.work=work;self.readPage=readPage}
    var selected:RecordedMeeting? {sessions.first {$0.id==selectedID}}
    @discardableResult func activate()->UUID {
        let token=UUID();appearance=token;visible=true;refresh();return token
    }
    func deactivate(_ token:UUID?=nil) {
        if let token,appearance != token {return}
        appearance=nil;visible=false;clear()
    }
    func invalidate() {let reload=visible;clear();if reload {refresh()}}
    func clear() {
        generation=UUID();if let job {work.cancel(id:job)};job=nil;busy=false;cursor=nil;hasOlder=false;error=nil
        sessions=[];sources=[:];selectedID=nil;status="Record a meeting or import audio to keep its sources together."
    }
    func refresh() {let selected=selectedID;clear();selectedID=selected;load(older:false)}
    func recordingSaved() {
        guard visible else {return}
        if sessions.isEmpty && !busy {refresh()}
        else {status="A recording was saved. Refresh to include the latest clips."}
    }
    func loadOlder() {guard hasOlder else {return};load(older:true)}
    private func load(older:Bool) {
        guard visible,!busy,allowed(),!store.isClosed else {return}
        let token=generation,store=store,readPage=readPage,cursor=older ? cursor:nil
        busy=true;error=nil
        job=work.launch(kind:.recordedMeetings,operation:{try Task.checkCancellation();return try readPage(store,cursor)}) {[weak self] result,cancelled in
            guard let self,self.generation==token else {return};self.job=nil;self.busy=false
            guard !cancelled,self.visible,self.allowed(),!store.isClosed else {return}
            do {
                let page=try result.get()
                try store.withCurrentRecordedMeetingPage(page) {
                    for source in page.sources {self.sources[source.id]=source}
                    self.sessions=RecordedMeetingPlanner.group(Array(self.sources.values));self.cursor=page.next;self.hasOlder=page.next != nil
                    if self.selectedID==nil || !self.sessions.contains(where:{$0.id==self.selectedID}) {self.selectedID=self.sessions.first?.id}
                    self.status="\(self.sessions.count) recording\(self.sessions.count==1 ? "":"s") · \(self.sources.count) clip\(self.sources.count==1 ? "":"s") loaded"+(self.hasOlder ? " · older recordings available":"")
                }
            }catch {self.error="Recordings could not refresh. Retry after the current library or privacy change."}
        }
        if job==nil {busy=false}
    }
    func askSelected(summarize:Bool=false) {
        guard allowed(),!busy,let source=selected?.sources.first,sources[source.id]==source else {return};beginChat?(source,summarize)
    }
    func open(_ source:RecordedMeetingSource) {
        guard allowed(),!busy,sources[source.id]==source else {return};openSource?(source)
    }
}
