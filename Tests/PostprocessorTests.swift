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

    func testTranscriptionAudioAddsFinalizationContext() {
        let captured: [Float] = [0.25, -0.5, 0.75]
        let input = TranscriptionAudio.addingTrailingSilence(to: captured)

        XCTAssertEqual(input.count, captured.count + 5_120)
        XCTAssertEqual(Array(input.prefix(captured.count)), captured)
        XCTAssertTrue(input.suffix(5_120).allSatisfy { $0 == 0 })
        XCTAssertEqual(captured.count, 3)
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
        XCTAssertEqual(entries.first?.status, .completed)
        XCTAssertNil(entries.first?.errorMessage)
    }

    func testFailedHistoryEntryCanBeRecoveredInPlace() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperown-history-failure-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }

        let store = try HistoryStore(databaseURL: databaseURL)
        let id = try await store.saveFailure(
            audioPath: "/tmp/recoverable.wav",
            durationMilliseconds: 2_500,
            source: "fluid-unified",
            errorMessage: "model unavailable"
        )

        let failedEntries = try await store.history(limit: 1)
        var entry = try XCTUnwrap(failedEntries.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.errorMessage, "model unavailable")
        XCTAssertEqual(entry.audioPath, "/tmp/recoverable.wav")

        try await store.resolveFailure(
            id: id,
            text: "recovered transcript",
            durationMilliseconds: nil,
            source: "fluid-unified"
        )

        let recoveredEntries = try await store.history(limit: 1)
        entry = try XCTUnwrap(recoveredEntries.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.text, "recovered transcript")
        XCTAssertEqual(entry.durationMilliseconds, 2_500)
        XCTAssertNil(entry.errorMessage)
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
        if let expectedLastWord = ProcessInfo.processInfo.environment[
            "WHISPEROWN_SMOKE_EXPECTED_LAST_WORD"
        ] {
            XCTAssertTrue(
                cleaned.lowercased().hasSuffix(expectedLastWord.lowercased()),
                "expected final word \(expectedLastWord), got: \(cleaned)"
            )
        }
    }
}
