import Foundation
import Combine
import AppKit
import OSwindCore

private struct PreparedRecordedMeetings:Sendable {
    let page:RecordedMeetingPage
    let sources:[String:RecordedMeetingSource]
    let sessions:[RecordedMeeting]
    let pages:Int
}
private struct RecordingRefreshPlan:Sendable {
    let pages:Int,selectedID:String?
    let retaining:[RecordedMeetingSource]
}

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
    private let readWindow:@Sendable (MemoryStore,Int,[RecordedMeetingSource])throws->RecordedMeetingWindow
    private let readRevision:@Sendable (MemoryStore)throws->RecordedMeetingRevision
    private let groupSources:@Sendable ([RecordedMeetingSource])throws->[RecordedMeeting]
    private let foreground:()->Bool,pollSeconds:()->Double
    private var sources=[String:RecordedMeetingSource](),cursor:RecordedMeetingCursor?,job:UUID?,revisionJob:UUID?,generation=UUID(),visible=false,appearance:UUID?
    private var loadedRevision:RecordedMeetingRevision?,loadedPages=0,pending:RecordingRefreshPlan?,checkPending=false
    private var monitor:Task<Void,Never>?
    init(store:MemoryStore,work:LibraryWorkRegistry,foreground:@escaping ()->Bool={NSApp?.isActive==true && !SessionState.locked},pollSeconds:@escaping ()->Double={ProcessInfo.processInfo.isLowPowerModeEnabled ? 10:3},readRevision:@escaping @Sendable (MemoryStore)throws->RecordedMeetingRevision={try $0.recordedMeetingRevision()},readWindow:@escaping @Sendable (MemoryStore,Int,[RecordedMeetingSource])throws->RecordedMeetingWindow={try $0.recordedMeetingWindow(pages:$1,retaining:$2)},groupSources:@escaping @Sendable ([RecordedMeetingSource])throws->[RecordedMeeting]={RecordedMeetingPlanner.group($0)},readPage:@escaping @Sendable (MemoryStore,RecordedMeetingCursor?)throws->RecordedMeetingPage = {try $0.recordedMeetingPage(before:$1)}) {
        self.store=store;self.work=work;self.foreground=foreground;self.pollSeconds=pollSeconds;self.readRevision=readRevision;self.readWindow=readWindow;self.readPage=readPage;self.groupSources=groupSources
    }
    var selected:RecordedMeeting? {sessions.first {$0.id==selectedID}}
    @discardableResult func activate()->UUID {
        let token=UUID();appearance=token;visible=true;refresh();monitor?.cancel()
        monitor=Task {[weak self] in
            while !Task.isCancelled {
                let interval=self?.pollSeconds() ?? 10
                do {try await Task.sleep(for:.seconds(max(0.05,interval)))}catch {return}
                guard let self,self.visible,!Task.isCancelled else {return}
                if self.foreground() {await self.checkForChanges()}
            }
        }
        return token
    }
    func deactivate(_ token:UUID?=nil) {
        if let token,appearance != token {return}
        appearance=nil;visible=false;monitor?.cancel();monitor=nil;clear()
    }
    func invalidate() {let reload=visible,plan=refreshPlan;clear();if reload {refresh(plan)}}
    func clear() {
        generation=UUID();if let job {work.cancel(id:job)};if let revisionJob {work.cancel(id:revisionJob)}
        job=nil;revisionJob=nil;busy=false;cursor=nil;hasOlder=false;error=nil;loadedRevision=nil;loadedPages=0;pending=nil;checkPending=false
        sessions=[];sources=[:];selectedID=nil;status="Record a meeting or import audio to keep its sources together."
    }
    private var refreshPlan:RecordingRefreshPlan {pending ?? .init(pages:loadedPages,selectedID:selectedID,retaining:selected?.sources ?? [])}
    func refresh() {refresh(refreshPlan,quiet:!sessions.isEmpty)}
    private func refresh(_ plan:RecordingRefreshPlan,retries:Int=1,quiet:Bool=false) {
        if quiet && !sessions.isEmpty {
            generation=UUID();if let job {work.cancel(id:job)};if let revisionJob {work.cancel(id:revisionJob)}
            job=nil;revisionJob=nil;busy=false;pending=nil;checkPending=false;error=nil;status="Updating recordings…"
        }else {clear();selectedID=plan.selectedID}
        load(older:false,plan:plan,retries:retries)
    }
    func recordingSaved() {guard visible else {return};_ = requestChangeCheck()}
    /// The timer and capture signal share one registry-owned revision reader.
    /// It has no public spinner, does nothing while hidden/locked, and never
    /// hydrates source text or invalidates on unrelated screen/vector writes.
    func checkForChanges()async {if let id=requestChangeCheck() {await work.wait(for:id)}}
    @discardableResult private func requestChangeCheck()->UUID? {
        guard visible,foreground(),allowed(),!store.isClosed else {return nil}
        if busy {checkPending=true;return nil}
        if let revisionJob {return revisionJob}
        if let pending {refresh(pending);return job}
        guard let loadedRevision else {refresh();return job}
        let token=generation,store=store,readRevision=readRevision
        revisionJob=work.launch(kind:.recordedMeetings,operation:{try Task.checkCancellation();return try readRevision(store)}) {[weak self] result,cancelled in
            guard let self,self.generation==token else {return};self.revisionJob=nil
            guard !cancelled,self.visible,self.foreground(),self.allowed() else {return}
            do {
                let current=try result.get()
                if current != loadedRevision {if current.hasSamePrivacy(as:loadedRevision) {self.refresh()}else {self.invalidate()}}
            }
            catch {self.clear();self.error="Recordings could not refresh. Retry after the current library or privacy change."}
        }
        return revisionJob
    }
    func loadOlder() {guard hasOlder else {return};load(older:true,plan:refreshPlan)}
    private func load(older:Bool,plan:RecordingRefreshPlan,retries:Int=1) {
        guard visible,!busy,allowed(),!store.isClosed else {return}
        let token=generation,store=store,readPage=readPage,readWindow=readWindow,groupSources=groupSources,cursor=older ? cursor:nil,existing=older ? sources:[:],expected=older ? loadedRevision:nil,priorPages=loadedPages
        busy=true;error=nil
        job=work.launch(kind:.recordedMeetings,operation:{
            try Task.checkCancellation()
            let page:RecordedMeetingPage,pages:Int
            var combined=existing
            if !older,plan.pages>0 {
                let window=try readWindow(store,plan.pages,plan.retaining)
                guard let last=window.pages.last,window.pages.allSatisfy({$0.revision==last.revision}) else {throw RecordedMeetingRefreshError.changed}
                page=last;pages=window.pages.count
                for part in window.pages {for source in part.sources {try Task.checkCancellation();combined[source.id]=source}}
                for source in window.retained {try Task.checkCancellation();combined[source.id]=source}
            }else {
                page=try readPage(store,cursor)
                if let expected,page.revision != expected {throw RecordedMeetingRefreshError.changed}
                pages=older ? priorPages+1:1
                for source in page.sources {try Task.checkCancellation();combined[source.id]=source}
            }
            let sessions=try groupSources(Array(combined.values));try Task.checkCancellation()
            return PreparedRecordedMeetings(page:page,sources:combined,sessions:sessions,pages:pages)
        }) {[weak self] result,cancelled in
            guard let self,self.generation==token else {return};self.job=nil;self.busy=false
            guard !cancelled,self.visible,self.allowed(),!store.isClosed else {return}
            do {
                let prepared=try result.get(),page=prepared.page
                try store.withCurrentRecordedMeetingPage(page) {
                    self.sources=prepared.sources;self.sessions=prepared.sessions;self.cursor=page.next;self.hasOlder=page.next != nil;self.loadedRevision=page.revision;self.loadedPages=prepared.pages
                    if self.selectedID==nil || !self.sessions.contains(where:{$0.id==self.selectedID}) {self.selectedID=self.sessions.first?.id}
                    self.status="\(self.sessions.count) recording\(self.sessions.count==1 ? "":"s") · \(self.sources.count) clip\(self.sources.count==1 ? "":"s") loaded"+(self.hasOlder ? " · older recordings available":"")
                }
                if self.checkPending {self.checkPending=false;_ = self.requestChangeCheck()}
            }catch {
                let budget=older ? priorPages+1:max(max(plan.pages,priorPages),1)
                let retry=RecordingRefreshPlan(pages:budget,selectedID:self.selectedID,retaining:self.selected?.sources ?? plan.retaining)
                if let freshness=error as? RecordedMeetingRefreshError {
                    if case .changed=freshness,retries>0,self.foreground() {self.refresh(retry,retries:retries-1,quiet:!self.sessions.isEmpty)}
                    else {self.clear();self.pending=retry;self.status="Recordings are updating. The current clips will appear shortly."}
                }else {self.clear();self.error="Recordings could not refresh. Retry after the current library or privacy change."}
            }
        }
        if job==nil {busy=false}
    }
    func askSelected(summarize:Bool=false) {
        guard allowed(),!busy,let source=selected?.sources.first,sources[source.id]==source else {return};beginChat?(source,summarize)
    }
    func open(_ source:RecordedMeetingSource) {
        guard allowed(),!busy,sources[source.id]==source else {return};openSource?(source)
    }
    deinit {monitor?.cancel()}
}
