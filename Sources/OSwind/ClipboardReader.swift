import Foundation
import AppKit
import OSwindCore

enum ClipboardAccess:Sendable {case allowed,approvalRequired,denied}
struct ClipboardProbe:Sendable {let access:ClipboardAccess;let changeCount:Int?}
struct ClipboardReader:Sendable {
    var probe:@Sendable ()async throws->ClipboardProbe
    var read:@Sendable (Int,String)async throws->ClipboardTextSnapshot
    var requestAccess:@Sendable ()async throws->ClipboardAccess={throw OSwindError.unavailable("Clipboard permission request is unavailable")}
    static var native:Self {NativeClipboardBackend().reader}
}

/// This adapter never opens a library or captures an application model. The
/// global worker retains its slot if AppKit waits on a pasteboard owner after
/// the caller cancels. Oversized provider data is rejected after retrieval;
/// no preallocation/RSS limit or operating-system permission grant is claimed.
struct NativeClipboardBackend:Sendable {
    private let ownedName:String?
    private let worker:ClipboardReadWorker
    init(){ownedName=nil;worker = .shared}
    init(ownedName:String,worker:ClipboardReadWorker=ClipboardReadWorker())throws {
        guard ownedName.hasPrefix("org.oswind.owned.clipboard."),ownedName.utf8.count<=128,!ownedName.utf8.contains(0) else {throw OSwindError.invalid("Invalid owned test pasteboard name")}
        self.ownedName=ownedName;self.worker=worker
    }
    private func board()->NSPasteboard {ownedName.map {NSPasteboard(name:.init($0))} ?? .general}
    private func access(_ board:NSPasteboard)->ClipboardAccess {
        // Only authored named boards bypass the general board's per-app policy.
        // They are inaccessible through the product settings/user workflow.
        if ownedName != nil {return .allowed}
        if #available(macOS 15.4,*) {
            switch board.accessBehavior {case .alwaysAllow:return .allowed;case .default,.ask:return .approvalRequired;case .alwaysDeny:return .denied;@unknown default:return .denied}
        }
        return .allowed
    }
    var reader:ClipboardReader {.init(probe:{
        try await worker.read {let pasteboard=board(),permission=access(pasteboard);return .init(access:permission,changeCount:permission == .allowed ? pasteboard.changeCount:nil)}
    },read:{expected,observedBundle in
        try await worker.read {
            guard !observedBundle.isEmpty,observedBundle.utf8.count<=512,!observedBundle.utf8.contains(0) else {throw ClipboardObservationSkip("Observed clipboard app is invalid")}
            let pasteboard=board()
            guard access(pasteboard) == .allowed else {throw ClipboardObservationSkip("Clipboard access needs explicit macOS approval")}
            guard pasteboard.changeCount==expected,let items=pasteboard.pasteboardItems,items.count==1 else {throw ClipboardObservationSkip("Clipboard contents changed or are outside single-item scope")}
            let item=items[0],types=item.types.map(\.rawValue)
            try ClipboardTextDraft.admittedTypes(types,itemCount:items.count)
            var source:String?
            if let type=item.types.first(where:{$0.rawValue.lowercased()=="org.nspasteboard.source"}) {
                guard let data=item.data(forType:type),data.count<=512,let value=String(data:data,encoding:.utf8) else {throw ClipboardObservationSkip("Clipboard source marker is malformed or oversized")}
                guard !value.isEmpty,Data(value.utf8)==Data(observedBundle.utf8) else {throw ClipboardObservationSkip("Clipboard source claim does not match the observed foreground app")};source=value
            }
            guard let data=item.data(forType:.string),!data.isEmpty,data.count<=ClipboardTextDraft.maximumTextBytes else {throw ClipboardObservationSkip("Clipboard text is unavailable or exceeds64KiB")}
            return .init(changeCount:expected,finalChangeCount:pasteboard.changeCount,itemCount:items.count,types:types,text:data,declaredSource:source)
        }
    },requestAccess:{
        try await worker.read {
            let pasteboard=board(),permission=access(pasteboard)
            guard permission == .approvalRequired else {return permission}
            // A separate explicit UI action authorizes this one access request.
            // Existing text is discarded, never returned to the observer/saved.
            _ = pasteboard.data(forType:.string)
            return access(pasteboard)
        }
    })}
}
