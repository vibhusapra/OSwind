import XCTest
@testable import OSwindCore

final class EvidenceTextTests: XCTestCase {
    func testTokenLimitedProviderResponsesAreNotCompletedAnswers() throws {
        XCTAssertThrowsError(try AnswerEngine.requireCompleteResponse(["done_reason":"length","message":["content":"unfinished planning"]],provider:.ollama))
        XCTAssertThrowsError(try AnswerEngine.requireCompleteResponse(["stop_reason":"max_tokens"],provider:.anthropic))
        XCTAssertThrowsError(try AnswerEngine.requireCompleteResponse(["choices":[["finish_reason":"length"]]],provider:.compatible))
        XCTAssertNoThrow(try AnswerEngine.requireCompleteResponse(["done_reason":"stop"],provider:.ollama))
        XCTAssertNoThrow(try AnswerEngine.requireCompleteResponse(["choices":[["finish_reason":"stop"]]],provider:.compatible))
        XCTAssertTrue(AnswerEngine.citationWarnings("Insufficient evidence.",sourceCount:2).isEmpty)
        XCTAssertFalse(AnswerEngine.citationWarnings("Insufficient evidence, but the budget is $100.",sourceCount:2).isEmpty)
    }
    func testAnswerFactsDeepInLongSourceReplaceIrrelevantOpening() {
        let text = String(repeating:"Routine unrelated screen context. ",count:200) + "Zephyr owner is Lina. The deadline is Thursday." + String(repeating:" Other background.",count:200)
        let excerpt = EvidenceText.excerpt(text,query:"Zephyr owner deadline",budget:300)
        XCTAssertTrue(excerpt.contains("Zephyr owner is Lina")); XCTAssertTrue(excerpt.contains("Thursday"))
        XCTAssertTrue(excerpt.hasPrefix("…")); XCTAssertTrue(excerpt.hasSuffix("…")); XCTAssertLessThan(excerpt.utf16.count,330)
    }
    func testDistantFactsUseTwoSourcePassagesWithoutFabricatingText() {
        let text = String(repeating:"Zephyr release boilerplate. ",count:100) + "Zephyr owner is Lina.\n" + String(repeating:"Unrelated technical details. ",count:300) + "Zephyr deadline is Thursday."
        let excerpt = EvidenceText.excerpt(text,query:"Zephyr owners deadlines",budget:400)
        XCTAssertTrue(excerpt.contains("Lina")); XCTAssertTrue(excerpt.contains("Thursday")); XCTAssertTrue(excerpt.contains("\n…\n"))
        for fragment in excerpt.components(separatedBy:"…").map({ $0.trimmingCharacters(in:.whitespacesAndNewlines) }) where !fragment.isEmpty { XCTAssertTrue(text.contains(fragment)) }
        XCTAssertLessThan(excerpt.utf16.count,430)
    }
    func testRecapAndUnanchoredQueryRetainOpeningAndEnding() {
        let text = "Opening agenda. " + String(repeating:"Middle context. ",count:300) + "Final decision: ship Thursday."
        for excerpt in [EvidenceText.excerpt(text,query:"nonmatching",budget:200),EvidenceText.excerpt(text,budget:200,summary:true)] {
            XCTAssertTrue(excerpt.hasPrefix("Opening agenda")); XCTAssertTrue(excerpt.contains("ship Thursday")); XCTAssertTrue(excerpt.contains("…"))
        }
        XCTAssertEqual(EvidenceText.excerpt("Short evidence.",budget:200),"Short evidence.")
    }
    func testCompactCardExcerptKeepsTheLateDeadlineVisible() {
        let text = String(repeating:"Background context for the Zephyr project. ",count:120)+"Zephyr owner is Lina. Zephyr deadline is Thursday."
        let excerpt = EvidenceText.excerpt(text,query:"Zephyr deadlines",budget:100)
        XCTAssertTrue(excerpt.contains("deadline is Thursday")); XCTAssertLessThan(excerpt.utf16.count,120)
    }
    func testUnicodeHighlightRangesPreserveComposedCharactersAndLiteralText() {
        let text = "🐈‍⬛ Cafe\u{301} résumé API_KEY ownership ship 杭州"
        let ranges = EvidenceText.matchRanges(in:text,query:"cafe resume ship 杭州")
        let found = ranges.map { (text as NSString).substring(with:$0) }
        XCTAssertEqual(found,["Cafe\u{301}","résumé","ship","杭州"])
        let long = String(repeating:"👩🏽‍💻 unrelated ",count:200)+"杭州 发布决定：周四。"+String(repeating:"👨‍👩‍👧‍👦",count:100)
        let excerpt = EvidenceText.excerpt(long,query:"杭州",budget:200)
        XCTAssertTrue(excerpt.contains("杭州 发布决定")); XCTAssertFalse(excerpt.contains("�"))
    }
    func testFullSourceDedupKeepsDifferentDecisionsAfterSharedBoilerplate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), boilerplate = String(repeating:"Zephyr release background. ",count:100)
        let first = Memory(id:"north",app:"Notes",title:"Release",text:boilerplate+"North owner is Lina.")
        let second = Memory(id:"south",app:"Notes",title:"Release",text:boilerplate+"South owner is Theo.")
        try store.insert(first); try store.insert(second)
        let result = try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Zephyr release owner",configuration:AIConfiguration())
        XCTAssertEqual(Set(result.sources.map(\.id)),["north","south"])
        XCTAssertTrue(result.text.contains("Lina")); XCTAssertTrue(result.text.contains("Theo"))
        XCTAssertTrue(result.warnings.contains { $0.contains("bounded excerpts") })
        let recap = try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Decisions?",configuration:AIConfiguration(),summarize:true)
        XCTAssertTrue(recap.warnings.contains { $0.contains("distributed sample") })
    }
}
