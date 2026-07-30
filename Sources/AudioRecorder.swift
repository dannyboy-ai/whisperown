import Cocoa
import AVFoundation

struct AudioRecording {
    let url: URL
    let samples: [Float]

    var durationMilliseconds: Int {
        Int((Double(samples.count) / 16_000) * 1_000)
    }
}

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var recordedSamples: [Float] = []
    private let samplesLock = NSLock()

    // The ASR model expects 16 kHz mono. Record natively at that rate so there's no
    // resample pass and recordings are ~3x smaller on disk.
    private static let targetSampleRate: Double = 16000

    private static var pcmFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    func startRecording() {
        recordedSamples = []
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        // Write to stderr (unbuffered) so the line survives a crash on this code path.
        fputs("Audio: hardware format sampleRate=\(hardwareFormat.sampleRate) channels=\(hardwareFormat.channelCount) common=\(hardwareFormat.commonFormat.rawValue) interleaved=\(hardwareFormat.isInterleaved)\n", stderr)
        fflush(stderr)

        let dataDir = getDataDirectory()
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dataDir.appendingPathComponent("recording-\(timestamp).wav")
        outputURL = url

        let fileSettings = Self.pcmFileSettings
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: fileSettings)
            audioFile = file
            fputs("Audio: file created OK (16kHz int16 mono)\n", stderr); fflush(stderr)
        } catch let err as NSError {
            fputs("Audio: file create FAILED domain=\(err.domain) code=\(err.code) desc=\(err.localizedDescription) userInfo=\(err.userInfo)\n", stderr); fflush(stderr)
            return
        }

        // AVAudioFile.write requires buffers in the file's processingFormat
        // (canonical float32 at the target rate), not the on-disk int16 format.
        // AVAudioFile handles the float→int16 encoding internally on write.
        let writeFormat = file.processingFormat
        fputs("Audio: processingFormat sampleRate=\(writeFormat.sampleRate) channels=\(writeFormat.channelCount) common=\(writeFormat.commonFormat.rawValue)\n", stderr); fflush(stderr)

        guard let conv = AVAudioConverter(from: hardwareFormat, to: writeFormat) else {
            fputs("Audio: AVAudioConverter init FAILED for \(hardwareFormat) -> \(writeFormat)\n", stderr); fflush(stderr)
            audioFile = nil
            return
        }
        converter = conv
        fputs("Audio: converter built OK\n", stderr); fflush(stderr)

        let ratio = writeFormat.sampleRate / hardwareFormat.sampleRate
        // Small buffer (512 frames ≈ 10ms @ 48kHz): the tap only delivers FULL
        // buffers, so whatever hasn't filled when you stop is dropped. 512 keeps
        // that dropped tail to ~10ms (imperceptible) instead of ~85ms at 4096,
        // which was clipping the final word when you stopped mid-syllable. The
        // extra callbacks are negligible CPU.
        inputNode.installTap(onBus: 0, bufferSize: 512, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self, let conv = self.converter, let outFile = self.audioFile else { return }
            let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: outFrameCapacity) else { return }
            var providedInput = false
            var convError: NSError?
            let status = conv.convert(to: outBuffer, error: &convError) { _, outStatus in
                if providedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                if let convError = convError {
                    fputs("Audio: converter error \(convError.localizedDescription)\n", stderr); fflush(stderr)
                }
                return
            }
            if outBuffer.frameLength == 0 { return }
            if let channel = outBuffer.floatChannelData?[0] {
                let samples = UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength))
                self.samplesLock.lock()
                self.recordedSamples.append(contentsOf: samples)
                self.samplesLock.unlock()
            }
            do {
                try outFile.write(from: outBuffer)
            } catch {
                fputs("Audio: file write error \(error.localizedDescription)\n", stderr); fflush(stderr)
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            fputs("Audio: engine.start OK\n", stderr); fflush(stderr)
            audioEngine = engine
        } catch let err as NSError {
            fputs("Audio: engine.start FAILED domain=\(err.domain) code=\(err.code) desc=\(err.localizedDescription) userInfo=\(err.userInfo)\n", stderr); fflush(stderr)
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            audioFile = nil
            converter = nil
        }
    }

    func stopRecording() -> AudioRecording? {
        let resultURL = outputURL

        // Stop the engine while the file is STILL open, so the last in-flight tap
        // buffers flush to disk. Closing the file first (as we used to) discarded
        // them and clipped the final syllable — recordings ended with 0ms trailing
        // silence and the last word could be cut. Close the file BEFORE removeTap,
        // though: a throw in removeTap must not leave a header-only file with no
        // audio (the original reason we closed early).
        audioEngine?.stop()
        audioFile = nil

        if tapInstalled, let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine = nil
        converter = nil
        guard let resultURL else { return nil }
        samplesLock.lock()
        let samples = recordedSamples
        recordedSamples = []
        samplesLock.unlock()
        return AudioRecording(url: resultURL, samples: samples)
    }

    private func getDataDirectory() -> URL {
        let recordings = Paths.inData("recordings")
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        return recordings
    }
}
