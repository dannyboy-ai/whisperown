import Foundation
import FluidAudio
import AVFoundation
import Swifter

final class Box: @unchecked Sendable { var s = "{\"error\":\"no result\"}" }

func loadSamples(_ p: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: p))
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}
func elog(_ m: String) { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }

@main
struct ANEServer {
    static func main() async throws {
        elog("loading FluidAudio (Parakeet · ANE)…")
        let models = try await AsrModels.downloadAndLoad()
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(models)
        elog("ANE warm, ready on 127.0.0.1:8006")

        let server = HttpServer()
        server.POST["/transcribe"] = { req in
            let bodyData = Data(req.body)
            elog("req: \(bodyData.count) bytes")
            let box = Box()
            let sema = DispatchSemaphore(value: 0)
            Task {
                let tmp = NSTemporaryDirectory() + UUID().uuidString + ".wav"
                do {
                    try bodyData.write(to: URL(fileURLWithPath: tmp))
                    let samples = try loadSamples(tmp)
                    var state = try TdtDecoderState(decoderLayers: 2)
                    let t0 = Date()
                    let r = try await mgr.transcribe(samples, decoderState: &state)
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let text = r.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    box.s = "{\"text\":\"\(text)\",\"infer_ms\":\(ms)}"
                    elog("ok \(ms)ms")
                } catch { box.s = "{\"error\":\"\(error)\"}"; elog("ERR \(error)") }
                try? FileManager.default.removeItem(atPath: tmp)
                sema.signal()
            }
            sema.wait()
            return HttpResponse.ok(.text(box.s))
        }
        try server.start(8006, forceIPv4: true)
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}
