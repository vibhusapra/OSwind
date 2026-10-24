import AppKit
import ScreenCaptureKit
import Vision

struct SnapshotCaptureDeferral:Error {var reason:String}
/// Internal seams let owned image fixtures exercise the actual admission path
/// without screen access, foreground changes or permission prompts.
@MainActor struct SnapshotCaptureFrame {
    var display:String
    var title:String
    var capture:() async throws -> CGImage
    var privacyStillMasked:() async throws -> Bool = {true}
}
@MainActor struct SnapshotCaptureEnvironment {
    var locked:()->Bool = {SessionState.locked}
    var permitted:()->Bool = {CGPreflightScreenCaptureAccess()}
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
    static func applications(_ content:SCShareableContent)->[SCRunningApplication] {
        var seen=Set<DisplayPrivacyApplication>()
        return (content.applications+content.windows.compactMap(\.owningApplication)).filter {seen.insert(.init(pid:$0.processID,bundle:$0.bundleIdentifier)).inserted}
    }
    static func identities(_ content:SCShareableContent)->([DisplayPrivacyApplication],[DisplayPrivacyWindow]) {
        (applications(content).map {.init(pid:$0.processID,bundle:$0.bundleIdentifier)},content.windows.map {window in
            .init(application:window.owningApplication.map {.init(pid:$0.processID,bundle:$0.bundleIdentifier)},title:window.title ?? "")
        })
    }
    static func frames(settings:AppSettings,context:WindowContext) async throws -> [SnapshotCaptureFrame] {
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        var filters=[(SCContentFilter,String,String)]()
        var validate:() async throws -> Bool = {true}
        if settings.allDisplays {
            let (apps,windows)=identities(content),policy=settings.privacy,own=Bundle.main.bundleIdentifier
            guard !SnapshotDisplayPrivacy.hasUnmaskableWindow(windows,policy:policy) else {throw SnapshotCaptureDeferral(reason:"An excluded window cannot be safely masked")}
            let blocked=SnapshotDisplayPrivacy.blocked(apps,windows:windows,policy:policy,ownBundle:own)
            let excluded=applications(content).filter {blocked.contains(.init(pid:$0.processID,bundle:$0.bundleIdentifier))}
            // Mask the entire app if any of its windows has an excluded title.
            // The app filter also covers new windows of those excluded apps.
            for display in content.displays {filters.append((SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[]),"display-\(display.displayID)","Display \(display.displayID)"))}
            validate={
                let latest=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true),current=identities(latest)
                return !SnapshotDisplayPrivacy.hasUnmaskableWindow(current.1,policy:policy) && SnapshotDisplayPrivacy.blocked(current.0,windows:current.1,policy:policy,ownBundle:own).isSubset(of:blocked)
            }
        } else {
            let candidates=content.windows.filter {$0.owningApplication?.processID==context.pid && $0.windowLayer==0 && $0.frame.width>100 && $0.frame.height>100}
            guard let index=FocusedWindowBinding.select(candidates.map {.init(frame:$0.frame,title:$0.title)},context:context) else {throw SnapshotCaptureDeferral(reason:"Waiting for an unambiguous focused window")}
            let window=candidates[index]
            guard settings.privacy.exclusion(app:context.bundle,title:window.title ?? context.title,url:context.url,isBrowser:context.browser)==nil else {throw SnapshotCaptureDeferral(reason:"Excluded window")}
            filters.append((SCContentFilter(desktopIndependentWindow:window),"window-\(window.windowID)",window.title ?? context.title))
            let id=window.windowID,title=window.title,frame=window.frame,policy=settings.privacy
            validate={
                let latest=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
                let current=latest.windows.filter {$0.owningApplication?.processID==context.pid && $0.windowLayer==0 && $0.frame.width>100 && $0.frame.height>100}
                guard let index=FocusedWindowBinding.select(current.map {.init(frame:$0.frame,title:$0.title)},context:context) else {return false}
                let selected=current[index]
                return selected.windowID==id && selected.title==title && selected.frame==frame && policy.exclusion(app:context.bundle,title:selected.title ?? context.title,url:context.url,isBrowser:context.browser)==nil
            }
        }
        return filters.map {filter,display,title in
            SnapshotCaptureFrame(display:display,title:title,capture:{
                let config=SCStreamConfiguration(),rect=filter.contentRect,scale=min(2.0,Double(settings.profile.maxDimension)/max(rect.width,rect.height))
                config.width=max(1,Int(rect.width*scale));config.height=max(1,Int(rect.height*scale));config.showsCursor=false;config.captureResolution = .best
                return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            },privacyStillMasked:validate)
        }
    }
}
