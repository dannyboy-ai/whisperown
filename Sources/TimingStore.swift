import Foundation

struct DictationTiming: Codable, Sendable {
    let timestamp: String
    let audioDurationMS: Int
    let audioFinalizeMS: Int
    let inferenceMS: Int
    let cleanupAndHistoryMS: Int
    let pasteIssueMS: Int
    let totalMS: Int
}

struct TimingSummary: Sendable {
    let sampleCount: Int
    let medianMS: Int
    let p95MS: Int
    let latest: DictationTiming?
}

actor TimingStore {
    static let shared = TimingStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func record(_ timing: DictationTiming) {
        do {
            var line = try encoder.encode(timing)
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: Paths.timings.path) {
                let handle = try FileHandle(forWritingTo: Paths.timings)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: Paths.timings, options: .atomic)
            }
            let current = summary()
            print(
                "Timing stop-to-paste p50=\(current.medianMS)ms p95=\(current.p95MS)ms n=\(current.sampleCount) " +
                "latest(finalize=\(timing.audioFinalizeMS) inference=\(timing.inferenceMS) " +
                "cleanup+history=\(timing.cleanupAndHistoryMS) paste=\(timing.pasteIssueMS) total=\(timing.totalMS))"
            )
        } catch {
            print("Could not save timing record: \(error.localizedDescription)")
        }
    }

    func summary() -> TimingSummary {
        let timings = load()
        let totals = timings.map(\.totalMS).sorted()
        return TimingSummary(
            sampleCount: totals.count,
            medianMS: percentile(totals, 0.50),
            p95MS: percentile(totals, 0.95),
            latest: timings.last
        )
    }

    private func load() -> [DictationTiming] {
        guard let data = try? Data(contentsOf: Paths.timings),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(DictationTiming.self, from: Data($0.utf8))
        }
    }

    private func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(ceil(Double(sorted.count) * fraction)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
