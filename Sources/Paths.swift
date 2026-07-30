import Foundation

// The app's on-disk home: ~/Library/Application Support/WhisperOwn/ (recordings,
// history DB, dictionary, models, and logs). Centralized so every call site agrees
// and the one-time rename from the former "Voice-to-Text" name runs exactly once.
enum Paths {
    static let dataDir: URL = {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let new = support.appendingPathComponent("WhisperOwn")
        let legacy = support.appendingPathComponent("Voice-to-Text")
        if fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: legacy, to: new)
        }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let oldDatabase = new.appendingPathComponent("voice-to-text.db\(suffix)")
            let currentDatabase = new.appendingPathComponent("whisperown.db\(suffix)")
            if fm.fileExists(atPath: oldDatabase.path),
               !fm.fileExists(atPath: currentDatabase.path) {
                try? fm.moveItem(at: oldDatabase, to: currentDatabase)
            }
        }
        return new
    }()

    static func inData(_ name: String) -> URL { dataDir.appendingPathComponent(name) }
    static var log: URL { inData("whisperown.log") }
    static var dictionary: URL { inData("dictionary.json") }
    static var models: URL { inData("Models") }
    static var timings: URL { inData("timings.jsonl") }
    static var database: URL { inData("whisperown.db") }
}
