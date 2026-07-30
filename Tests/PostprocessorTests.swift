import Foundation
import XCTest
@testable import WhisperOwn

final class PostprocessorTests: XCTestCase {
    private struct Fixture: Decodable {
        let input: String
        let expected: String
    }

    func testCleanupFixturesAndIdempotency() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "postprocess", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 81)

        for fixture in fixtures {
            let once = Postprocessor.process(fixture.input, dictionary: [:])
            XCTAssertEqual(once, fixture.expected, "input: \(fixture.input)")
            XCTAssertEqual(
                Postprocessor.process(once, dictionary: [:]),
                once,
                "not idempotent for input: \(fixture.input)"
            )
        }
    }

    func testDictionaryUsesWholeWordsAndPreservesReplacementCase() {
        let dictionary = ["whisper own": "WhisperOwn", "bow": "BOW"]
        XCTAssertEqual(
            Postprocessor.process("whisper own uses a bow, not a rainbow. ", dictionary: dictionary),
            "WhisperOwn uses a BOW, not a rainbow"
        )
    }

    func testActualThankYouIsNeverDiscarded() {
        XCTAssertEqual(
            Postprocessor.process("let's get moving. thank you. ", dictionary: [:]),
            "let's get moving. thank you"
        )
        XCTAssertEqual(Postprocessor.process("thank you. ", dictionary: [:]), "thank you")
    }
    func testNativeHistoryRoundTrip() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperown-history-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }

        let store = try HistoryStore(databaseURL: databaseURL)
        let id = try await store.save(
            audioPath: "/tmp/dictation.wav",
            text: "native history",
            durationMilliseconds: 1_250,
            source: "fluid-unified"
        )
        let entries = try await store.history(limit: 1)
        XCTAssertEqual(entries.first?.id, id)
        XCTAssertEqual(entries.first?.text, "native history")
        XCTAssertEqual(entries.first?.durationMilliseconds, 1_250)
        XCTAssertEqual(entries.first?.source, "fluid-unified")
    }

    func testRealAudioPipelineWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISPEROWN_SMOKE_WAV"] else {
            throw XCTSkip("Set WHISPEROWN_SMOKE_WAV to exercise the local model")
        }
        let transcriber = FluidTranscriber()
        let raw = try await transcriber.transcribe(URL(fileURLWithPath: path))
        let cleaned = Postprocessor.process(raw, dictionary: [:])
        XCTAssertFalse(cleaned.isEmpty)
        XCTAssertGreaterThan(cleaned.split(separator: " ").count, 1)
    }
}
