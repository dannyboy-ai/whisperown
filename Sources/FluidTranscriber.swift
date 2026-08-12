import Foundation
import AVFoundation
import FluidAudio

enum ModelPreparationState: Sendable {
    case preparing
    case progress(fraction: Double, detail: String)
    case ready
    case failed(String)
    case cancelled
}

enum TranscriptionAudio {
    // Parakeet needs right-side acoustic context to finalize the last token. A
    // stopped recording has none, so provide the 320 ms finalization window used
    // by Parakeet streaming pipelines without changing the saved recording.
    static let trailingSilenceSampleCount = 5_120

    static func addingTrailingSilence(to samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var input = samples
        input.reserveCapacity(samples.count + trailingSilenceSampleCount)
        input.append(contentsOf: repeatElement(0, count: trailingSilenceSampleCount))
        return input
    }
}

actor FluidTranscriber {
    private var manager = UnifiedAsrManager()
    private var preparation: Task<Void, Error>?
    private(set) var isReady = false

    private static let modelFolderName = "parakeet-unified-en-0.6b"
    private static let requiredArtifacts = [
        "vocab.json",
        "parakeet_unified_encoder_int8.mlmodelc",
        "parakeet_unified_decoder.mlmodelc",
        "parakeet_unified_joint_decision_single_step.mlmodelc",
    ]

    nonisolated static var modelIsInstalled: Bool {
        artifactsExist(at: Paths.models.appendingPathComponent(modelFolderName))
    }

    private nonisolated static func artifactsExist(at directory: URL) -> Bool {
        requiredArtifacts.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }
    }

    func prepare(
        status: @escaping @Sendable (ModelPreparationState) -> Void = { _ in }
    ) async throws {
        if isReady {
            status(.ready)
            return
        }
        if let preparation {
            try await preparation.value
            status(.ready)
            return
        }

        status(.preparing)
        try Self.prepareModelStorage()
        let activeManager = manager
        let task = Task {
            let started = ProcessInfo.processInfo.systemUptime
            try await activeManager.loadModels(to: Paths.models) { progress in
                let detail: String
                switch progress.phase {
                case .listing:
                    detail = "Checking model files…"
                case .downloading(let completed, let total):
                    detail = "Downloading file \(min(completed + 1, total)) of \(total)…"
                case .compiling:
                    detail = "Preparing model for this Mac…"
                }
                status(.progress(fraction: progress.fractionCompleted, detail: detail))
            }
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            print("Fluid Unified ready in \(elapsedMS) ms at \(Paths.models.path)")
        }
        preparation = task

        do {
            try await task.value
            isReady = true
            status(.ready)
        } catch is CancellationError {
            preparation = nil
            manager = UnifiedAsrManager()
            status(.cancelled)
            throw CancellationError()
        } catch {
            preparation = nil
            manager = UnifiedAsrManager()
            status(.failed(error.localizedDescription))
            throw error
        }
    }

    func cancelPreparation() {
        preparation?.cancel()
    }
    func transcribe(_ wavURL: URL) async throws -> String {
        let file = try AVAudioFile(forReading: wavURL)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw FluidTranscriberError.couldNotAllocateAudioBuffer
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw FluidTranscriberError.couldNotAllocateAudioBuffer
        }
        return try await transcribe(Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        ))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await prepare()
        let started = ProcessInfo.processInfo.systemUptime
        let text = try await manager.transcribe(
            TranscriptionAudio.addingTrailingSilence(to: samples)
        )
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        print("Fluid Unified inference: \(elapsedMS) ms")
        return text
    }

    private nonisolated static func prepareModelStorage() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.models, withIntermediateDirectories: true)

        let destination = Paths.models.appendingPathComponent(modelFolderName)
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            .appendingPathComponent(modelFolderName)

        if fm.fileExists(atPath: destination.path), !artifactsExist(at: destination) {
            try fm.removeItem(at: destination)
            print("Removed incomplete Fluid Unified model cache before retry")
        }

        if !fm.fileExists(atPath: destination.path), artifactsExist(at: legacy) {
            try fm.moveItem(at: legacy, to: destination)
            print("Migrated Fluid Unified model into WhisperOwn's data directory")
        }
    }
}

enum FluidTranscriberError: Error {
    case couldNotAllocateAudioBuffer
}
