import AppKit
import ScreenCaptureKit
import Vision
import ApplicationServices

struct SnapshotCaptureDeferral:Error {var reason:String}
/// Internal seams let owned image fixtures exercise the actual admission path
/// without screen access, foreground changes or permission prompts.
@MainActor struct SnapshotCaptureFrame {
    var display:String
    var title:String
    var capture:() async throws -> CGImage
    var includeAccessibilityText:Bool = true
    var privacyStillMasked:() async throws -> Bool = {true}
}
@MainActor struct SnapshotCaptureEnvironment {
    var locked:()->Bool = {SessionState.locked}
    var permitted:()->Bool = {CGPreflightScreenCaptureAccess()}
    var accessibilityPermitted:()->Bool = {AXIsProcessTrusted()}
    var idleSeconds:()->Double = {CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.null)}
    var textCommitPermitted:@Sendable ()->Bool = {!SessionState.locked && AXIsProcessTrusted()}
    var textEmbedding:@Sendable (String,LocalEmbedder) throws -> [Float]? = {text,embedder in
        try Task.checkCancellation();let vector=embedder.embed(text)
        try Task.checkCancellation();return vector
    }
    var context:(String?) async -> WindowContext? = {await AccessibilityContext.read(targetBundleID:$0)}
    var identityCurrent:(WindowContext,String?)->Bool = {AccessibilityContext.identityCurrent($0,targetBundleID:$1)}
    var frames:(AppSettings,WindowContext) async throws -> [SnapshotCaptureFrame] = {try await NativeSnapshotSource.frames(settings:$0,context:$1)}
    var recognize:@Sendable (CGImage) throws -> [TextRegion] = {image in
        try Task.checkCancellation()
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true;request.automaticallyDetectsLanguage=true
        try VNImageRequestHandler(cgImage:image).perform([request]);try Task.checkCancellation()
        return (request.results ?? []).compactMap {observation in
            guard let text=observation.topCandidates(1).first?.string else {return nil}
            let b=observation.boundingBox;return TextRegion(text:text,x:b.minX,y:b.minY,width:b.width,height:b.height)
        }
    }
}
enum SnapshotContextBinding {
    static func matches(_ original:WindowContext,_ current:WindowContext)->Bool {
        guard !original.secure,!current.secure,original.pid>0,original.pid==current.pid,original.bundle==current.bundle,original.title==current.title,original.url==current.url,original.bounds==current.bounds else {return false}
        if let b=current.bounds {return [b.minX,b.minY,b.width,b.height].allSatisfy(\.isFinite) && b.width>0 && b.height>0}
        return true
    }
}
struct DisplayPrivacyApplication:Hashable,Sendable {var pid:pid_t;var bundle:String}
struct DisplayPrivacyWindow:Sendable {var application:DisplayPrivacyApplication?;var title:String}
enum SnapshotDisplayPrivacy {
    static func blocked(_ applications:[DisplayPrivacyApplication],windows:[DisplayPrivacyWindow],policy:PrivacyPolicy,ownBundle:String?)->Set<DisplayPrivacyApplication> {
        Set(Set(applications).union(windows.compactMap(\.application)).filter {app in
            let browser=WindowContext(app:"",bundle:app.bundle,pid:app.pid,title:"",url:nil,accessibilityText:"",secure:false).browser
            return browser || app.bundle==ownBundle || app.bundle=="com.oswind.desktop" || policy.exclusion(app:app.bundle,title:"",url:nil) != nil || windows.contains {window in window.application==app && policy.exclusion(app:app.bundle,title:window.title,url:nil) != nil}
        })
    }
    static func hasUnmaskableWindow(_ windows:[DisplayPrivacyWindow],policy:PrivacyPolicy)->Bool {
        windows.contains {$0.application==nil && policy.exclusion(app:"",title:$0.title,url:nil) != nil}
    }
}
@MainActor private enum NativeSnapshotSource {
    struct Plan {
        var filter:SCContentFilter
        var display:String
        var title:String
        var geometry:SnapshotRegionGeometry?=nil
        var crop:SnapshotRegion?=nil
        var includeAX:Bool=true
        var attached:(SCShareableContent)->Bool={_ in true}
    }
    static func applications(_ content:SCShareableContent)->[SCRunningApplication] {
        var seen=Set<DisplayPrivacyApplication>()
        return (content.applications+content.windows.compactMap(\.owningApplication)).filter {seen.insert(.init(pid:$0.processID,bundle:$0.bundleIdentifier)).inserted}
    }
    static func identities(_ content:SCShareableContent)->([DisplayPrivacyApplication],[DisplayPrivacyWindow]) {
        (applications(content).map {.init(pid:$0.processID,bundle:$0.bundleIdentifier)},content.windows.map {window in
            .init(application:window.owningApplication.map {.init(pid:$0.processID,bundle:$0.bundleIdentifier)},title:window.title ?? "")
        })
    }
    static func descriptor(_ display:SCDisplay)->SnapshotDisplayDescriptor? {
        guard let id=SnapshotRegionSettings.displayID(display.displayID) else {return nil}
        return .init(identifier:id,displayID:display.displayID,frame:display.frame,size:CGSize(width:display.width,height:display.height))
    }
    static func frames(settings:AppSettings,context:WindowContext) async throws -> [SnapshotCaptureFrame] {
        guard settings.visualCaptureMode != .accessibility else {throw SnapshotCaptureDeferral(reason:"Text-only mode never captures screen pixels")}
        guard settings.snapshotRegions.valid else {throw SnapshotCaptureDeferral(reason:"Display or crop configuration is invalid") }
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        var plans=[Plan]()
        var validate:(SCShareableContent)->Bool = {_ in true}
        if settings.allDisplays {
            let (apps,windows)=identities(content),policy=settings.privacy,own=Bundle.main.bundleIdentifier
            guard !SnapshotDisplayPrivacy.hasUnmaskableWindow(windows,policy:policy) else {throw SnapshotCaptureDeferral(reason:"An excluded window cannot be safely masked")}
            let blocked=SnapshotDisplayPrivacy.blocked(apps,windows:windows,policy:policy,ownBundle:own)
            let excluded=applications(content).filter {blocked.contains(.init(pid:$0.processID,bundle:$0.bundleIdentifier))}
            // Mask the entire app if any of its windows has an excluded title.
            // The app filter also covers new windows of those excluded apps.
            let descriptors=content.displays.compactMap(descriptor)
            if settings.snapshotRegions.selectedDisplays==nil,descriptors.count != content.displays.count {throw SnapshotCaptureDeferral(reason:"A display identity is unavailable")}
            let selected:[SnapshotDisplayDescriptor]
            do {selected=try settings.snapshotRegions.resolved(descriptors)}catch {throw SnapshotCaptureDeferral(reason:error.localizedDescription)}
            for source in selected {
                guard let display=content.displays.first(where:{$0.displayID==source.displayID}) else {continue}
                let id=source.identifier,crop=settings.snapshotRegions.displayCrops[id],geometry=try SnapshotRegionGeometry(size:source.size,region:crop,maximumDimension:settings.profile.maxDimension)
                let stillAttached:(SCShareableContent)->Bool = {latest in source.current(in:latest.displays.compactMap(descriptor))}
                let suffix=crop.map {"-crop-\($0.x)-\($0.y)-\($0.width)-\($0.height)"} ?? ""
                plans.append(.init(filter:SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[]),display:"display-"+id+suffix,title:"Display \(display.displayID)",geometry:geometry,includeAX:false,attached:stillAttached))
            }
            guard !plans.isEmpty else {throw SnapshotCaptureDeferral(reason:"No selected display is attached · choose a display in Settings")}
            validate={latest in
                let current=identities(latest)
                return !SnapshotDisplayPrivacy.hasUnmaskableWindow(current.1,policy:policy) && SnapshotDisplayPrivacy.blocked(current.0,windows:current.1,policy:policy,ownBundle:own).isSubset(of:blocked)
            }
        } else {
            let candidates=content.windows.filter {$0.owningApplication?.processID==context.pid && $0.windowLayer==0 && $0.frame.width>100 && $0.frame.height>100}
            guard let index=FocusedWindowBinding.select(candidates.map {.init(frame:$0.frame,title:$0.title)},context:context) else {throw SnapshotCaptureDeferral(reason:"Waiting for an unambiguous focused window")}
            let window=candidates[index]
            guard settings.privacy.exclusion(app:context.bundle,title:window.title ?? context.title,url:context.url,isBrowser:context.browser)==nil else {throw SnapshotCaptureDeferral(reason:"Excluded window")}
            let crop=settings.snapshotRegions.focusedWindowCrop
            if let crop {_ = try crop.rect(in:window.frame.size)}
            let suffix=crop.map {"-crop-\($0.x)-\($0.y)-\($0.width)-\($0.height)"} ?? ""
            plans.append(.init(filter:SCContentFilter(desktopIndependentWindow:window),display:"window-\(window.windowID)"+suffix,title:window.title ?? context.title,crop:crop,includeAX:crop==nil))
            let id=window.windowID,title=window.title,frame=window.frame,policy=settings.privacy
            validate={latest in
                let current=latest.windows.filter {$0.owningApplication?.processID==context.pid && $0.windowLayer==0 && $0.frame.width>100 && $0.frame.height>100}
                guard let index=FocusedWindowBinding.select(current.map {.init(frame:$0.frame,title:$0.title)},context:context) else {return false}
                let selected=current[index]
                return selected.windowID==id && selected.title==title && selected.frame==frame && policy.exclusion(app:context.bundle,title:selected.title ?? context.title,url:context.url,isBrowser:context.browser)==nil
            }
        }
        return plans.map {plan in
            let filter=plan.filter
            return SnapshotCaptureFrame(display:plan.display,title:plan.title,capture:{
                let config=SCStreamConfiguration(),rect=filter.contentRect,scale=min(2.0,Double(settings.profile.maxDimension)/max(rect.width,rect.height))
                if let geometry=plan.geometry {config.sourceRect=geometry.sourceRect;config.width=geometry.outputWidth;config.height=geometry.outputHeight}
                else {config.width=max(1,Int(rect.width*scale));config.height=max(1,Int(rect.height*scale))};config.showsCursor=false;config.captureResolution = .best
                if plan.crop != nil {config.ignoreShadowsSingleWindow=true}
                let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                return try plan.crop?.crop(image) ?? image
            },includeAccessibilityText:plan.includeAX,privacyStillMasked:{
                let latest=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
                return validate(latest) && plan.attached(latest)
            })
        }
    }
}
