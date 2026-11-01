import XCTest
import CSQLite
import Darwin
import CryptoKit
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testPublicationQueueActualOld32InitializedWriterAndFreshReadersSurviveRetraction()throws {
        try actualOld32(sourceErase:false)
    }
    func testPublicationQueueActualOld32InitializedWriterAndFreshReadersSurviveSourceErasure()throws {
        try actualOld32(sourceErase:true)
    }
    private func actualOld32(sourceErase:Bool)throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PUBLICATION_OLD32_CLI"] else {throw XCTSkip("Opt in with the actual qualified prior schema32 CLI")}
        let binary=URL(fileURLWithPath:path).resolvingSymlinksInPath(),expected="ce600b7d4c74eaaba65db61050b9b369a05352a9fe80c145e7a438448e01e6e2"
        func hash()throws->String {SHA256.hash(data:try Data(contentsOf:binary)).map{String(format:"%02x",$0)}.joined()}
        guard FileManager.default.isExecutableFile(atPath:binary.path),try hash()==expected else {throw OSwindError.invalid("Use the exact owned qualified prior32 CLI")}
        let child=Process(),input=Pipe(),fm=FileManager.default
        // The frozen executable runs normally even when this XCTest parent is
        // sanitized. Do not inject the parent's test runtime into old CLI/lsof.
        var ordinaryEnvironment=ProcessInfo.processInfo.environment;ordinaryEnvironment.removeValue(forKey:"DYLD_INSERT_LIBRARIES")
        let stdout=root.appendingPathComponent("old32-initialized.stdout"),stderr=root.appendingPathComponent("old32-initialized.stderr")
        XCTAssertTrue(fm.createFile(atPath:stdout.path,contents:nil,attributes:[.posixPermissions:0o600]));XCTAssertTrue(fm.createFile(atPath:stderr.path,contents:nil,attributes:[.posixPermissions:0o600]))
        let output=try FileHandle(forWritingTo:stdout),errors=try FileHandle(forWritingTo:stderr);defer {try? output.close();try? errors.close()}
        child.executableURL=binary;child.standardInput=input;child.standardOutput=output;child.standardError=errors;child.environment=ordinaryEnvironment
        defer {try? input.fileHandleForWriting.close();if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL);child.waitUntilExit()}}
        func awaitExit(_ process:Process,seconds:TimeInterval=25)throws {
            let deadline=ProcessInfo.processInfo.systemUptime+seconds
            while process.isRunning && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
            guard !process.isRunning else {_=Darwin.kill(process.processIdentifier,SIGKILL);process.waitUntilExit();throw OSwindError.unavailable("Owned prior32 process exceeded its bound")}
            process.waitUntilExit()
        }
        func run(_ executable:URL,_ arguments:[String])throws->(Int32,Data,Data) {
            let process=Process(),out=Pipe(),err=Pipe();process.executableURL=executable;process.arguments=arguments;process.standardOutput=out;process.standardError=err;process.environment=ordinaryEnvironment
            try process.run();try awaitExit(process)
            return (process.terminationStatus,out.fileHandleForReading.readDataToEndOfFile(),err.fileHandleForReading.readDataToEndOfFile())
        }
        var postOpenObserved=false
        try withQueueFixture(citations:1,beforeQueueInstall:{store,_ in
            child.arguments=["--data",store.root.path,"collect","--stdin"];try child.run()
            let deadline=ProcessInfo.processInfo.systemUptime+20,target=store.root.appendingPathComponent(".media-admission.lock").resolvingSymlinksInPath().path
            while child.isRunning && ProcessInfo.processInfo.systemUptime<deadline {
                let (_,bytes,_)=try run(URL(fileURLWithPath:"/usr/sbin/lsof"),["-a","-p",String(child.processIdentifier),"-Ffln"])
                try bytes.write(to:self.root.appendingPathComponent("old32-post-open-lsof.txt"),options:.atomic)
                var descriptorObserved=false
                for line in String(decoding:bytes,as:UTF8.self).components(separatedBy:"\n") {
                    if line.hasPrefix("n"),URL(fileURLWithPath:String(line.dropFirst())).resolvingSymlinksInPath().path==target {descriptorObserved=true}
                }
                if descriptorObserved {
                    // Darwin lsof does not report this flock's mode. Verify it
                    // directly: exclusive must be blocked, shared must succeed.
                    // No other process uses this newly authored private root.
                    let probe=Darwin.open(target,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
                    guard probe>=0 else {throw OSwindError.invalid("Cannot inspect the owned prior32 media lease")}
                    if flock(probe,LOCK_EX|LOCK_NB)==0 {_=flock(probe,LOCK_UN)}
                    else if errno==EWOULDBLOCK || errno==EAGAIN {
                        if flock(probe,LOCK_SH|LOCK_NB)==0 {postOpenObserved=true;_=flock(probe,LOCK_UN)}
                    }
                    Darwin.close(probe)
                }
                if postOpenObserved {break}
                Thread.sleep(forTimeInterval:0.05)
            }
            guard postOpenObserved,child.isRunning else {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL);child.waitUntilExit()};throw OSwindError.unavailable("Actual prior32 collector never reached its post-open shared lease before queue installation; owned lsof/stdout/stderr retained")}
        }) {f in
            defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL);child.waitUntilExit()}}
            XCTAssertTrue(postOpenObserved);XCTAssertTrue(child.isRunning)
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let chat=try XCTUnwrap(f.b.chats().first),oldTurn=try XCTUnwrap(f.b.chatTurns(chat.id).first)
            let before=try run(binary,["--data",f.b.root.path,"chat","show",chat.id]);XCTAssertEqual(before.0,0,String(decoding:before.2,as:UTF8.self))
            let beforeJSON=try XCTUnwrap(JSONSerialization.jsonObject(with:before.1) as? [String:Any]);XCTAssertEqual((beforeJSON["turns"] as? [Any])?.count,1)
            let (next,proof,revision)=try queueReplacement(f,text:"New independent answer after actual old writer 👩🏽‍💻 e\u{301}")
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            if sourceErase {
                let source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),deletion=try f.ac.journal.delete(key:source.key)
                XCTAssertTrue(deletion.context.contains(revision.dot));_=try queueReceive(deletion,f.ac,service)
                XCTAssertEqual(try count(f.b,"memories"),0);XCTAssertEqual(try f.b.chats().first?.title,"Conversation")
            }else {_=try service.receive(revision,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Missing declaration must not fetch sources")})}
            let hidden=try run(binary,["--data",f.b.root.path,"chat","show",chat.id]);XCTAssertEqual(hidden.0,0,String(decoding:hidden.2,as:UTF8.self))
            let hiddenJSON=try XCTUnwrap(JSONSerialization.jsonObject(with:hidden.1) as? [String:Any]);XCTAssertEqual((hiddenJSON["turns"] as? [Any])?.count,0)
            let markdown=root.appendingPathComponent("old32-retracted.md"),export=try run(binary,["--data",f.b.root.path,"chat","export",chat.id,markdown.path]);XCTAssertEqual(export.0,0)
            XCTAssertFalse(try String(contentsOf:markdown,encoding:.utf8).contains(oldTurn.answer.text))
            let wire:[String:Any]=["format":"OSwind collector batch","version":1,"collectorID":"org.oswind.queue-old32-fixture","records":[["key":"post-open-note","timestamp":"2026-10-31T11:00:00Z","text":"Owned prior32 note written after queue installation and retraction","app":"Owned","bundleID":"org.oswind.queue-old32-fixture","title":"Owned compatibility note"]]]
            try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:wire));try input.fileHandleForWriting.close();try awaitExit(child)
            let errorText=try String(contentsOf:stderr,encoding:.utf8);XCTAssertEqual(child.terminationStatus,0,errorText)
            let report=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:stdout)) as? [String:Any]);XCTAssertEqual(report["imported"] as? Int,1)
            XCTAssertEqual(try count(f.b,"memories"),sourceErase ? 1:2);XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,1);try f.queue.checkAccounting()
            // Drain the legitimate old native mutation through the real outgoing
            // processor before admitting more peer work on this connection.
            try publicationDrain(f.b,f.bc,f.inbox)
            let ownerKey=try next.identity.key;XCTAssertFalse(try f.bc.journal.outbox().contains{$0.key == ownerKey && $0.mutation == .delete})
            if sourceErase {_=try service.receive(revision,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Independent answer cannot fetch erased evidence")})}
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Current publication must complete after the real old-client write")}
            XCTAssertEqual(try f.b.chatTurns(chat.id).first?.id,oldTurn.id);XCTAssertTrue(try f.queue.isComplete(next.identity))
            let restored=try run(binary,["--data",f.b.root.path,"chat","show",chat.id]);XCTAssertEqual(restored.0,0);XCTAssertTrue(String(decoding:restored.1,as:UTF8.self).contains("New independent answer after actual old writer"))
            lease.release()
            let erasureGeneration=try f.b.withRoutineDatabase {try BackupErasureFence.current($0)}
            let removed=try run(binary,["--data",f.b.root.path,"chat","delete",chat.id]);XCTAssertEqual(removed.0,0,String(decoding:removed.2,as:UTF8.self))
            XCTAssertNotEqual(try f.b.withRoutineDatabase {try BackupErasureFence.current($0)},erasureGeneration)
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),0);try f.queue.checkAccounting()
            XCTAssertEqual(try hash(),expected)
            print("PUBLICATION_OLD32 sourceErase=\(sourceErase) exactFrozenBinary=true initializedBeforeQueueInstall=true postOpenLeaseObserved=true oldWriterAfterRetraction=true freshReadExportAndDelete=true stableLocalID=true completionAndAccounting=true")
        }
    }
}
