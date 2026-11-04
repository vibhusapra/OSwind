import Foundation
import Combine
import OSwindCore

struct RecordingNameReview:Identifiable,Sendable {
    let id=UUID()
    let source:RecordedMeetingSource
    let expected:RecordedMeetingDetailsSnapshot?
}

/// Selected-recording work only. Archive pagination never hydrates all clips
/// to discover names. The registry owns readers, writes and actor completions.
@MainActor final class RecordingNamesModel:ObservableObject {
    @Published private(set) var rows=[RecordedMeetingDetailsSnapshot]()
    @Published private(set) var loading=false
    @Published private(set) var loaded=false
    @Published private(set) var saving=false
    @Published private(set) var error:String?
    @Published private(set) var editorError:String?
    @Published private(set) var notice:String?
    @Published var editor:RecordingNameReview?
    @Published var removal:RecordingNameReview?
    @Published var draft=""
    var allowed:()->Bool={false}
    var refreshArchive:(()->Void)?
    private let store:MemoryStore,work:LibraryWorkRegistry
    private let read:@Sendable (MemoryStore,RecordedMeetingSource)throws->[RecordedMeetingDetailsSnapshot]
    private let save:@Sendable (MemoryStore,String,RecordedMeetingSource,RecordedMeetingDetailsSnapshot?)throws->RecordedMeetingDetailsSnapshot
    private let remove:@Sendable (MemoryStore,RecordedMeetingDetailsSnapshot,RecordedMeetingSource)throws->HistoryErasureResult
    private var source:RecordedMeetingSource?,archiveRevision:RecordedMeetingRevision?
    private var readJob:UUID?,writeJob:UUID?,generation=UUID()
    private var reviewDraft:(session:String,text:String)?
    init(store:MemoryStore,work:LibraryWorkRegistry,
         read:@escaping @Sendable (MemoryStore,RecordedMeetingSource)throws->[RecordedMeetingDetailsSnapshot]={try $0.recordedMeetingDetails(for:$1)},
         save:@escaping @Sendable (MemoryStore,String,RecordedMeetingSource,RecordedMeetingDetailsSnapshot?)throws->RecordedMeetingDetailsSnapshot={try $0.saveRecordedMeetingName($1,for:$2,replacing:$3)},
         remove:@escaping @Sendable (MemoryStore,RecordedMeetingDetailsSnapshot,RecordedMeetingSource)throws->HistoryErasureResult={try $0.removeRecordedMeetingName($1,for:$2)}) {
        self.store=store;self.work=work;self.read=read;self.save=save;self.remove=remove
    }
    var canEdit:Bool {allowed() && loaded && !loading && !saving && rows.count<=1 && source != nil}
    var canSave:Bool {allowed() && !saving && editor != nil && editor?.source.sessionKey==source?.sessionKey && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && draft.count<=200}
    func select(_ source:RecordedMeetingSource?,revision:RecordedMeetingRevision?) {
        guard let source,let revision else {clear();return}
        if self.source?.sessionKey != source.sessionKey {
            clear()
        }
        if self.source==source,archiveRevision==revision,(loading || loaded) {return}
        self.source=source;archiveRevision=revision;load()
    }
    /// A quiet archive refresh hides obsolete labels but preserves an open
    /// authored draft. A privacy/departure clear below also cancels its write.
    func suspend() {
        generation=UUID();if let readJob {work.cancel(id:readJob)};readJob=nil
        rows=[];loading=false;loaded=false;error=nil;archiveRevision=nil
    }
    func clear() {
        suspend();if let writeJob {work.cancel(id:writeJob)};writeJob=nil
        source=nil;editor=nil;removal=nil;draft="";editorError=nil;reviewDraft=nil;saving=false;notice=nil;removalWrite=nil
    }
    private struct Prepared:Sendable {let values:[RecordedMeetingDetailsSnapshot],revision:RecordedMeetingRevision}
    private func load() {
        guard allowed(),let source,!store.isClosed else {return}
        generation=UUID();if let readJob {work.cancel(id:readJob)}
        let token=generation,store=store,read=read
        rows=[];loaded=false;loading=true;error=nil
        readJob=work.launch(kind:.recordedMeetings,operation:{
            try Task.checkCancellation();let before=try store.recordedMeetingRevision()
            let values=try read(store,source);try Task.checkCancellation()
            guard try store.recordedMeetingRevision()==before else {throw RecordedMeetingRefreshError.changed}
            return Prepared(values:values,revision:before)
        }) {[weak self] result,cancelled in
            guard let self,self.generation==token else {return};self.readJob=nil;self.loading=false
            guard !cancelled,self.allowed(),self.source==source,!store.isClosed else {return}
            do {
                let value=try result.get()
                try store.withCurrentRecordedMeetingRevision(value.revision) {
                    self.rows=value.values;self.loaded=true;self.error=nil
                    if let preserved=self.reviewDraft,preserved.session==source.sessionKey,self.rows.count<=1 {
                        self.reviewDraft=nil;self.presentEditor(draft:preserved.text)
                    }
                }
            }catch {self.rows=[];self.loaded=false;self.error="Recording names could not refresh. Refresh recordings to review the current name."}
        }
        if readJob==nil {loading=false}
    }
    func beginEditing() {guard canEdit else {return};presentEditor(draft:rows.first?.name ?? "")}
    private func presentEditor(draft:String) {
        guard let source,canEdit else {return}
        self.draft=draft;editorError=nil;editor=RecordingNameReview(source:source,expected:rows.first)
    }
    func cancelEditor() {guard !saving else {return};reviewDraft=nil;editor=nil}
    func reviewLatest() {
        guard !saving,let editor else {return}
        reviewDraft=(editor.source.sessionKey,draft);self.editor=nil
    }
    func editorDismissed() {
        guard !saving else {if editor==nil {clear()};return}
        if reviewDraft != nil,allowed() {if let refreshArchive {refreshArchive()}else {load()}}
        else {draft="";editorError=nil}
    }
    func saveEditor() {
        guard canSave,let reviewed=editor else {return}
        let text=draft,store=store,save=save,request=reviewed.id
        saving=true;editorError=nil
        writeJob=work.launch(kind:.recordedMeetings,operation:{
            try Task.checkCancellation();return try save(store,text,reviewed.source,reviewed.expected)
        }) {[weak self] result,cancelled in
            guard let self,self.editor?.id==request else {return};self.writeJob=nil;self.saving=false
            guard !cancelled,self.allowed(),!store.isClosed else {return}
            do {
                _=try result.get();self.editor=nil;self.reviewDraft=nil;self.draft="";self.editorError=nil
                if let refreshArchive=self.refreshArchive {refreshArchive()}else {self.load()}
            }catch {
                if case OSwindError.invalid(let reason)=error {self.editorError=reason}
                else {self.editorError="The recording or saved name changed, or the library is unavailable. Your draft is preserved. Review the latest name before saving."}
            }
        }
        if writeJob==nil {saving=false;editorError="The library is closing. Your draft has not been submitted."}
    }
    func requestRemoval(_ expected:RecordedMeetingDetailsSnapshot) {
        guard allowed(),loaded,!loading,!saving,rows.contains(expected),let source else {return}
        removal=RecordingNameReview(source:source,expected:expected)
    }
    func cancelRemoval() {removal=nil}
    func confirmRemoval() {
        guard allowed(),!saving,let reviewed=removal,let expected=reviewed.expected,reviewed.source.sessionKey==source?.sessionKey else {return}
        removal=nil;saving=true;error=nil;notice=nil
        let store=store,remove=remove,token=UUID();let prior=writeJob
        if let prior {work.cancel(id:prior)}
        removalWrite=token
        writeJob=work.launch(kind:.recordedMeetings,operation:{
            try Task.checkCancellation();return try remove(store,expected,reviewed.source)
        }) {[weak self] result,cancelled in
            guard let self,self.removalWrite==token else {return};self.removalWrite=nil;self.writeJob=nil;self.saving=false
            guard !cancelled,self.allowed(),!store.isClosed else {return}
            do {
                let value=try result.get()
                self.notice=value.searchCacheRemoved && value.pendingMedia==0 ? nil:"Name removed. Search or retained-media cleanup is still pending."
                if let refreshArchive=self.refreshArchive {refreshArchive()}else {self.load()}
            }catch {self.error="The name could not be removed. Refresh recordings and review its current definition."}
        }
        if writeJob==nil {saving=false;removalWrite=nil}
    }
    private var removalWrite:UUID?
}
