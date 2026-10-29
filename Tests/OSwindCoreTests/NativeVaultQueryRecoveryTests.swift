import XCTest
import Darwin
@testable import OSwindCore

/// Native mutations and final observations are real APFS IPC. The deliberately
/// interrupted results come from real Python SIGINT controls injected into the
/// internal read-only transport, not from a claim that hdiutil was signalled.
final class NativeVaultQueryRecoveryTests:XCTestCase {
    private final class Events:@unchecked Sendable {
        private let lock=NSLock();private var values=[VaultNativeSummary]()
        func add(_ value:VaultNativeDiagnostic) {lock.lock();values.append(value.summary);lock.unlock()}
        var snapshot:[VaultNativeSummary] {lock.lock();defer {lock.unlock()};return values}
        func save(_ name:String)throws {
            if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_VAULT_QUERY_TRACE_DIR"] {
                let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try JSONEncoder().encode(snapshot).write(to:directory.appendingPathComponent(name+"-"+UUID().uuidString+".json"),options:.withoutOverwriting)
            }
        }
    }
    private actor InterruptedQueries {
        let repeatInventory:Bool
        private var interrupted=Set<String>()
        var injections=0
        init(repeatInventory:Bool=false) {self.repeatInventory=repeatInventory}
        func run(_ operation:VaultNativeOperation,_ executable:String,_ arguments:[String],_ timeout:Double) async throws ->VaultProcessResult {
            let interrupt:Bool
            if repeatInventory {interrupt=operation == .attachmentInventory}
            else {interrupt=interrupted.insert(operation.rawValue).inserted}
            if interrupt {
                injections+=1
                return try await VaultProcess.run("/usr/bin/python3",["-c","import os,signal;signal.signal(signal.SIGINT,signal.SIG_DFL);os.kill(os.getpid(),signal.SIGINT)"],timeout:timeout)
            }
            return try await VaultProcess.run(executable,arguments,timeout:timeout)
        }
    }
    func testOwnedVaultRecoversOneRealHelperSIGINTForEachReadOnlyOperation() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned APFS query-recovery fixture; no normal library or real Keychain")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-query-recovery-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),events=Events(),queries=InterruptedQueries()
        let driver=NativeVaultDriver(observer:{events.add($0)},queryProcess:{try await queries.run($0,$1,$2,$3)})
        let vault=try LibraryVault(package:package,nativeDriver:driver),ordinary=try LibraryVault(package:package)
        var active:MemoryStore?
        do {
            let created=try await LibraryVault.create(at:package,name:"Owned query recovery",capacityGiB:1,passphrase:secret,nativeDriver:driver)
            XCTAssertEqual(created.state,.locked)
            _ = try await vault.unlock(passphrase:secret)
            let store=try MemoryStore(root:vault.libraryURL);active=store
            try store.insert(Memory(id:"query-owned",text:"Owned query interruption must preserve this note"))
            _ = try await vault.lock(store:store);active=nil
            _ = try await ordinary.unlock(passphrase:secret)
            let reopened=try MemoryStore(root:ordinary.libraryURL);active=reopened
            XCTAssertEqual(try reopened.get("query-owned")?.text,"Owned query interruption must preserve this note")
            _ = try await ordinary.lock(store:reopened);active=nil
            let detached=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(detached)
            let injected=await queries.injections;XCTAssertEqual(injected,3)
            let failures=events.snapshot.filter {$0.termination == .signal && $0.status==SIGINT}
            XCTAssertEqual(Set(failures.map(\.operation.rawValue)),Set(["attachmentInventory","encryptionProbe","volumeInfo"]))
            XCTAssertEqual(failures.count,3)
            let mutations=events.snapshot.filter {$0.operation.mutates}
            XCTAssertGreaterThanOrEqual(mutations.count,2)
            XCTAssertTrue(mutations.allSatisfy {$0.termination == .exit && $0.status==0})
            try events.save("query-recovery-completed");try FileManager.default.removeItem(at:root)
        } catch {
            try? active?.close();_ = try? await ordinary.lock()
            try? events.save("query-recovery-failed")
            // Preserve failed fixture files; never force detach or remove an
            // attachment whose independent detached state is unconfirmed.
            throw error
        }
    }
    func testRepeatedInterruptsRefuseStatusAfterTwoCallsAndPermitOrdinaryRecovery() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned APFS repeated query-interruption control")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-query-refusal-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),ordinary=try LibraryVault(package:package)
        let queries=InterruptedQueries(repeatInventory:true),events=Events()
        let driver=NativeVaultDriver(observer:{events.add($0)},queryProcess:{try await queries.run($0,$1,$2,$3)})
        let interrupted=try LibraryVault(package:package,nativeDriver:driver)
        var active:MemoryStore?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned repeated query control",capacityGiB:1,passphrase:secret)
            _ = try await ordinary.unlock(passphrase:secret)
            let store=try MemoryStore(root:ordinary.libraryURL);active=store;try store.insert(Memory(id:"query-control",text:"Owned refusal control"))
            _ = try await ordinary.lock(store:store);active=nil
            do {_ = try await interrupted.status();XCTFail("Repeated interruption reported a protected state")}
            catch let failure as VaultNativeFailure {XCTAssertEqual(failure.summary.termination,.signal);XCTAssertEqual(failure.summary.status,SIGINT)}
            let injected=await queries.injections;XCTAssertEqual(injected,2)
            XCTAssertEqual(events.snapshot.count,2);XCTAssertFalse(events.snapshot.contains {$0.operation.mutates})
            _ = try await ordinary.unlock(passphrase:secret)
            let reopened=try MemoryStore(root:ordinary.libraryURL);active=reopened
            XCTAssertEqual(try reopened.get("query-control")?.text,"Owned refusal control")
            _ = try await ordinary.lock(store:reopened);active=nil
            let detached=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(detached)
            try events.save("query-refusal-completed");try FileManager.default.removeItem(at:root)
        } catch {try? active?.close();_ = try? await ordinary.lock();try? events.save("query-refusal-failed");throw error}
    }
}
