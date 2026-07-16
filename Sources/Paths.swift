import Foundation

// The app's on-disk home: ~/Library/Application Support/WhisperOwn/ (recordings,
// history DB, dictionary, config, logs). Centralized so every call site agrees,
// and so the one-time rename from the former "Voice-to-Text" name runs exactly
// once. The backend performs the same migration (server/paths.py); whichever
// process starts first moves the directory, and both are idempotent.
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
        return new
    }()

    static func inData(_ name: String) -> URL { dataDir.appendingPathComponent(name) }
    static var log: URL { inData("whisperown.log") }
    static var dictionary: URL { inData("dictionary.json") }
}
