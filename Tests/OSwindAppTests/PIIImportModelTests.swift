import XCTest
@testable import OSwindCore
@testable import OSwind

private final class AppImportPIIBackend:PIINativeBackend,@unchecked Sendable {
    let gate:ImportWorkerGate
    private let lock=NSLock()
    private var count=0
    init(_ gate:ImportWorkerGate) {self.gate=gate}
    var closes:Int {lock.withLock {count}}
    func close() {lock.withLock {count+=1}}
    func prepare(_ document:PIIDocument)async throws->PIIWindowPlan {try PIIWindowPlan.make(document:document,prompt:[50281,50369],tokenLimit:512) {_ in [1]}}
    func predict(_ window:PIIWindowPlan.Window)async throws->PIINativeOutput {
        try gate.pause()
        return .init(sourceSHA256:window.sourceSHA256,windowID:window.id,modelID:PIIInspector.expectedModelID(.cpu),shape:[1,window.input.words.count,12,3],logits:Array(repeating:-20,count:window.input.words.count*36))
    }
}
extension ImportLifecycleModelTests {
    func testLearnedPrivacySettingsChangeCancelsAndDrainsActualInference() async throws {
        app.settings.piiImports.enabled=true;app.settings.piiImports.compute = .cpu
        let gate=ImportWorkerGate();defer {gate.release()}
        let backend=AppImportPIIBackend(gate),scanner=PIIImportScanner(inspector:PIIInspector(loader:{backend}))
        app.importJSONFile(try fixture(),scannerFactory:{_ in scanner})
        await fulfillment(of:[gate.entered],timeout:10)
        app.settings.piiImports.threshold=0.6
        let model=app!,drain=Task {await model.cancelJSONImportAndWait()}
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertTrue(app.hasPendingJSONImport);XCTAssertEqual(backend.closes,0);XCTAssertFalse(app.store.isClosed)
        gate.release();await drain.value
        XCTAssertFalse(app.hasPendingJSONImport);XCTAssertEqual(backend.closes,1);XCTAssertEqual(try app.store.stats().count,0)
    }
    func testGUIModelFailureRefusesWithoutOrdinaryImportFallback() async throws {
        app.settings.piiImports.enabled=true
        app.importJSONFile(try fixture(),scannerFactory:{_ in throw OSwindError.unavailable("Owned missing PII assets")})
        try await finishImport(app)
        XCTAssertEqual(try app.store.stats().count,0);XCTAssertTrue(app.importStatus.contains("Owned missing PII assets"))
    }
    func testActualNativeGUIJSONAndLimitlessImportWorkers() async throws {
        guard let cache=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_SETUP_CACHE"] else {throw XCTSkip("Explicit verified native PII cache absent")}
        let email="+1 (202) 555-0100",text="Owned support note: my private phone number is "+email+". Keep this private."
        let json=root.appendingPathComponent("native.json"),page=root.appendingPathComponent("limitless.json")
        try JSONEncoder().encode([Memory(id:"native-owned",kind:.note,app:"Fixture",bundleID:"org.example.fixture",title:"Fixture",text:text)]).write(to:json)
        let record:[String:Any]=["id":"native-limitless","title":"Fixture","markdown":text,"startTime":"2026-10-29T12:00:00Z","endTime":"2026-10-29T12:01:00Z","isStarred":false,"contents":[]]
        try JSONSerialization.data(withJSONObject:["data":["lifelogs":[record]],"meta":["lifelogs":["count":1,"nextCursor":NSNull()]]]).write(to:page)
        for compute:PIIComputePolicy in [.cpu,.coreML] {
            app.settings.piiImports.enabled=true;app.settings.piiImports.compute=compute;app.settings.piiImports.cacheRoot=cache
            app.importJSONFile(json);try await finishImport(app)
            XCTAssertTrue(app.importStatus.contains("Additional experimental PII masking"),app.importStatus)
            XCTAssertFalse(try XCTUnwrap(app.store.get("native-owned")).text.contains(email))
            app.importJSONFile(page,limitlessAPI:true);try await finishImport(app)
            XCTAssertTrue(app.importStatus.contains("Additional experimental PII masking"),app.importStatus)
            XCTAssertFalse(try XCTUnwrap(app.store.get(try LimitlessImport.sourceID("native-limitless"))).text.contains(email))
        }
        XCTAssertEqual(try app.store.stats().count,2)
    }
}
