import XCTest
import CryptoKit
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testPublicationQueueActualOld32FreshClientRefusesRetractionLibraryWithoutMutation()throws {try old32FreshRefusal(sourceErase:false)}
    func testPublicationQueueActualOld32FreshClientRefusesSourceErasureLibraryWithoutMutation()throws {try old32FreshRefusal(sourceErase:true)}
    private func old32FreshRefusal(sourceErase:Bool)throws {
        guard let supplied=ProcessInfo.processInfo.environment["OSWIND_TEST_PUBLICATION_OLD32_CLI"] else {throw XCTSkip("Requires the exact qualified prior32 executable")}
        let binary=URL(fileURLWithPath:supplied).resolvingSymlinksInPath(),expected="ce600b7d4c74eaaba65db61050b9b369a05352a9fe80c145e7a438448e01e6e2"
        func hash(_ file:URL)throws->String {SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()}
        guard FileManager.default.isExecutableFile(atPath:binary.path),try hash(binary)==expected else {throw OSwindError.invalid("Use the exact frozen prior32 executable")}
        var env=ProcessInfo.processInfo.environment;env.removeValue(forKey:"DYLD_INSERT_LIBRARIES")
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let chat=try XCTUnwrap(f.b.chats().first),old=try XCTUnwrap(f.b.chatTurns(chat.id).first)
            let (next,proof,revision)=try queueReplacement(f,text:"Current independent answer after legacy refusal")
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            if sourceErase {
                let source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),deletion=try f.ac.journal.delete(key:source.key)
                _=try queueReceive(deletion,f.ac,service)
            }else {_=try service.receive(revision,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Source-free replacement cannot fetch")})}
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,1)
            func databaseFiles()throws->[String:String] {
                var result=[String:String]()
                for name in ["memory.sqlite","memory.sqlite-wal"] {let file=f.b.root.appendingPathComponent(name);if FileManager.default.fileExists(atPath:file.path) {result[name]=try hash(file)}}
                return result
            }
            let before=try databaseFiles()
            for command in [["stats"],["note","Owned incompatible note"],["chat","show",chat.id],["erase","retry-media"],["collect","--stdin"]] {
                let child=Process(),out=Pipe(),err=Pipe();child.executableURL=binary;child.arguments=["--data",f.b.root.path]+command;child.environment=env;child.standardInput=FileHandle.nullDevice;child.standardOutput=out;child.standardError=err
                try child.run();let stdout=out.fileHandleForReading.readDataToEndOfFile(),stderr=err.fileHandleForReading.readDataToEndOfFile();child.waitUntilExit()
                XCTAssertNotEqual(child.terminationStatus,0);XCTAssertTrue(String(decoding:stderr,as:UTF8.self).contains("newer OSwind version"),String(decoding:stderr,as:UTF8.self));XCTAssertTrue(stdout.isEmpty)
                XCTAssertEqual(try databaseFiles(),before,"Refusal must preserve both committed DB and WAL bytes")
            }
            XCTAssertEqual(try count(f.b,"chat_turns"),0);try f.queue.checkAccounting()
            if sourceErase {_=try service.receive(revision,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Independent answer cannot fetch erased source")})}
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Current client must still complete after incompatible clients refuse")}
            XCTAssertEqual(try f.b.chatTurns(chat.id).first?.id,old.id);XCTAssertTrue(try f.queue.isComplete(next.identity));try f.queue.checkAccounting();XCTAssertEqual(try hash(binary),expected)
            print("PUBLICATION_OLD32_FENCE sourceErase=\(sourceErase) freshCommandsRefused=5 databaseAndWALUnchanged=true currentCompletion=true")
        }
    }
}
