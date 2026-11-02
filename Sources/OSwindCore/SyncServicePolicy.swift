import Foundation

/// The service never rewrites an immutable peer version to make it pass policy.
/// A denied version stays pending; its hash must continue to mean the same bytes.
struct SyncServicePolicy {
    let settings:AppSettings
    var signature:String {get throws {
        struct Fields:Encodable {let privacy:PrivacyPolicy;let retainAudio:Bool;let visualCaptureMode:VisualCaptureMode}
        return try SyncProtocolLimits.hex(SyncProtocolLimits.encode(Fields(privacy:settings.privacy,retainAudio:settings.retainAudio,visualCaptureMode:settings.visualCaptureMode)))
    }}

    func admitSource(app:String,title:String,url:String?,media:Set<SyncMediaRole>)throws {
        let browser=WindowContext.isBrowser(bundle:app)
        guard settings.privacy.exclusion(app:app,title:title,url:url,isBrowser:browser)==nil,
              !media.contains(.image) || settings.privacy.retainImages,
              !media.contains(.audio) || settings.retainAudio,
              !media.contains(.video) || settings.visualCaptureMode == .replay else {throw SyncPublicationPolicyDenied()}
    }

    func admit(_ record:SyncPortableRecord)throws {
        do {try admitContent(record)}catch let error as SyncPublicationPolicyDenied {throw SyncPublicationPolicyDenied(identity:error.identity ?? record.identity)}
    }
    private func admitContent(_ record:SyncPortableRecord)throws {
        try record.validate()
        // Scan content fields explicitly. Protocol UUIDs, hashes and session
        // tokens are structural identifiers, not prose or credential values.
        // Running a credit-card detector over those can reject valid identities.
        var text=[String]()
        func filter(_ value:SyncFilterBody) {text += [value.query]+[value.app,value.tag,value.speaker].compactMap{$0}}
        switch record.body {
        case .source(let body):
            try admitSource(app:body.bundleID,title:body.title,url:body.url,media:Set(body.media.map(\.role)))
            text += [body.app,body.bundleID,body.title,body.text]+[body.url,body.display].compactMap{$0}+body.tags+body.regions.map(\.text)
            if let speech=body.transcript {try admit(speech)}
            if let visual=body.visualRecording {try admit(visual)}
            if let recap=body.recap {text += [recap.provider]+recap.sources.map(\.match)}
        case .conversation(let body):text += [body.title]
        case .turn(let body):text += [body.question,body.text,body.provider]+body.warnings;filter(body.filter)
        case .conversationCitation(let body),.recapCitation(let body):text += [body.link.match]
        case .routine(let body):text += [body.title,body.prompt]+[body.app,body.tag].compactMap{$0}
        case .routineRun(let body):text += [body.message].compactMap{$0};filter(body.filter)
        case .entity(let body):text += [body.name,body.detail]
        case .entityAlias(let body):text += [body.key,body.label]
        case .entityMention(let body):text += [body.surface,body.method]
        case .entityRejection(let body):text += [body.key]
        case .projectRejection,.evidencePin:break
        }
        try strings(text)
    }

    func admitRow(_ identity:SyncObjectIdentity,_ row:SyncRowSnapshot)throws {
        let schema=identity.table.schema
        guard row.cells.count==schema.columns.count else {throw OSwindError.invalid("Sync policy row width differs")}
        if identity.table == .source {
            guard let index=schema.columns.firstIndex(of:"payload"),case .blob(let data)=row.cells[index] else {throw OSwindError.invalid("Sync source policy requires its native payload")}
            let memory=try JSONDecoder().decode(Memory.self,from:data)
            do {try admit(memory)}catch let error as SyncPublicationPolicyDenied {throw SyncPublicationPolicyDenied(identity:error.identity ?? identity)}
        }
    }

    func admit(_ memory:Memory)throws {
        var roles=Set<SyncMediaRole>()
        if memory.imagePath != nil {roles.insert(.image)}
        if memory.audioPath != nil {roles.insert(.audio)}
        if memory.videoPath != nil {roles.insert(.video)}
        try admitSource(app:memory.bundleID,title:memory.title,url:memory.url,media:roles)
        // Media preparation precedes the complete portable body. Check source
        // text/metadata first; never persist a private chunk before this check.
        try strings([memory.app,memory.bundleID,memory.title,memory.url,memory.text,memory.display].compactMap({$0})+memory.tags+memory.regions.map(\.text))
        if let speech=memory.transcript {try admit(speech)}
        if let visual=memory.visualRecording {try admit(visual)}
    }

    private func strings(_ values:[String])throws {
        for value in values {try Task.checkCancellation();guard !settings.privacy.sanitize(value).redacted else {throw SyncPublicationPolicyDenied()}}
    }
    private func admit(_ speech:SpeechTranscript)throws {
        guard try speech.sanitized(policy:settings.privacy).transcript==speech else {throw SyncPublicationPolicyDenied()}
    }
    private func admit(_ visual:VisualRecording)throws {
        guard try visual.sanitized(policy:settings.privacy)==visual else {throw SyncPublicationPolicyDenied()}
        try strings([visual.codec]+visual.frames.flatMap{[$0.text]+$0.regions.map(\.text)})
    }
}
