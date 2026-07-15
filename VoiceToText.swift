import Cocoa
import AVFoundation
import Carbon.HIToolbox

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: AudioRecorder!
    private var isRecording = false
    private var globePressed = false
    private var lastTranscription: String?
    private var lastWavURL: URL?
    private var historyWindow: HistoryWindowController?
    private var dictionaryPanel: DictionaryPanelController?
    private var rulesPanel: RulesPanelController?
    private var backendMenuItems: [NSMenuItem] = []
    private var onboarding: OnboardingWindowController?
    private var hotkeyArmed = false

    private var appBundlePath: String {
        return Bundle.main.bundlePath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // autosaveName + isVisible: macOS 26 (Tahoe) hides unnamed status items
        // in a Control Center-managed registry. Named items survive.
        statusItem.autosaveName = "VoiceToText"
        statusItem.isVisible = true
        updateMenubarIcon(recording: false)

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "WhisperOwn", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let globeHint = NSMenuItem(title: "Press Globe (Fn) to start/stop recording", action: nil, keyEquivalent: "")
        globeHint.isEnabled = false
        menu.addItem(globeHint)

        let repasteHint = NSMenuItem(title: "Ctrl+Cmd+V to re-paste last", action: nil, keyEquivalent: "")
        repasteHint.isEnabled = false
        menu.addItem(repasteHint)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Re-transcribe last", action: #selector(reTranscribeLast), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal recording in Finder", action: #selector(revealLastRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dictionary…", action: #selector(showDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Cleanup Rules…", action: #selector(showRules), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        let backendHeader = NSMenuItem(title: "Transcription backend", action: nil, keyEquivalent: "")
        backendHeader.isEnabled = false
        menu.addItem(backendHeader)
        // The backend transcribes on the local Parakeet-MLX server by default;
        // pointing it at a remote box is configured in the backend's config.json.
        for (title, mode) in [("Parakeet (local · fast)", "parakeet")] {
            let item = NSMenuItem(title: title, action: #selector(setBackend(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.target = self
            menu.addItem(item)
            backendMenuItems.append(item)
        }
        menu.addItem(NSMenuItem(title: "Test Backend", action: #selector(testWhisperServer), keyEquivalent: "t"))
        syncBackendFile()
        updateBackendCheckmarks()

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Permissions Guide…", action: #selector(showPermissionsGuide), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Edit menu so Cmd-X/C/V/A work in the Dictionary text fields. An accessory
        // app has no visible menu bar, but the key-equivalents still route to the
        // first responder — without this, paste into a text field does nothing.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = editMenu
        let mainMenu = NSMenu(); mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        recorder = AudioRecorder()
        setupLogging()

        // Permission gate. The old flow fired the microphone AND accessibility
        // system prompts back-to-back at launch ("bang bang") with no context —
        // the worst first impression. Instead: read status silently (no prompt),
        // and if anything is missing hand off to the guided Permissions Guide,
        // which fires each OS prompt one at a time, only when the user clicks its
        // step. If both are already granted, just arm the hotkey and we're done.
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = AXIsProcessTrusted()  // status read only — does NOT prompt
        // Always attempt the tap. When trusted it arms the Globe key; when NOT
        // trusted the failed attempt still registers WhisperOwn in the Accessibility
        // list (no dialog), so the guide can just open the pane and the user finds
        // WhisperOwn already listed — one window, ready to toggle.
        setupHotKeyMonitoring()

        if micOK && axOK {
            print("WhisperOwn ready. Press Globe (Fn) to start/stop recording. Ctrl+Cmd+V to re-paste.")
        } else {
            print("First-run: missing \(micOK ? "" : "microphone ")\(axOK ? "" : "accessibility ")— opening Permissions Guide")
            showPermissionsGuide()
        }
    }

    @objc private func showPermissionsGuide() {
        if let existing = onboarding { existing.show(); return }
        // An accessory (menubar-only) app can't normally show a focused window;
        // flip to a regular app for the duration of the guide, then flip back.
        NSApp.setActivationPolicy(.regular)
        let controller = OnboardingWindowController(onDone: { [weak self] in
            guard let self = self else { return }
            NSApp.setActivationPolicy(.accessory)
            self.onboarding = nil
            // A CGEvent tap can't be armed in-process after launch, so if
            // accessibility just landed and we aren't armed yet, relaunch — the
            // fresh process sees both grants and skips the guide entirely.
            if AXIsProcessTrusted() && !self.hotkeyArmed {
                self.restart()
            }
        })
        onboarding = controller
        controller.show()
    }

    private func setupLogging() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice-to-Text")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("voice-to-text.log").path

        // Redirect stderr to log file (print() goes to stderr in release)
        freopen(logPath, "a", stderr)
        freopen(logPath, "a", stdout)
    }

    private func updateMenubarIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let name = recording ? "mic.fill" : "mic"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: recording ? "recording" : "WhisperOwn") else { return }
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: recording ? .semibold : .regular)
        if recording {
            // Solid RED mic via palette color (non-template). A template image +
            // contentTintColor .systemRed was rendering BLANK on macOS 26 — and the
            // system's own orange mic indicator sits elsewhere, so our slot went empty.
            let img = base.withSymbolConfiguration(size.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))) ?? base
            img.isTemplate = false
            button.image = img
            button.contentTintColor = nil
        } else {
            let img = base.withSymbolConfiguration(size) ?? base
            img.isTemplate = true
            button.image = img
            button.contentTintColor = nil
        }
    }

    private func setupHotKeyMonitoring() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return appDelegate.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("ERROR: Failed to create event tap — is Accessibility permission granted?")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hotkeyArmed = true
        print("Globe (Fn) key monitoring active")
    }

    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let hasCtrl = flags.contains(.maskControl)
            let hasCmd = flags.contains(.maskCommand)
            let noShift = !flags.contains(.maskShift)
            let noAlt = !flags.contains(.maskAlternate)

            if keyCode == 0x09 && hasCtrl && hasCmd && noShift && noAlt {
                DispatchQueue.main.async { self.rePasteLastTranscription() }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let rawFlags = event.flags.rawValue
        let fnNowPressed = (rawFlags & 0x800000) != 0

        let modifierMask = CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
        let otherModifiers = (rawFlags & modifierMask) != 0

        // Toggle: each clean Fn press flips recording state. globePressed tracks
        // the physical key so we only fire once per press, not on auto-repeat.
        if fnNowPressed && !globePressed && !otherModifiers {
            globePressed = true
            DispatchQueue.main.async {
                if self.isRecording {
                    self.stopRecordingAndTranscribe()
                } else {
                    self.startRecording()
                }
            }
            return nil
        } else if !fnNowPressed && globePressed {
            globePressed = false
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func rePasteLastTranscription() {
        guard let text = lastTranscription else {
            print("No previous transcription to re-paste")
            return
        }
        print("Re-pasting: \(text)")
        pasteText(text)
    }

    private func startRecording() {
        isRecording = true
        updateMenubarIcon(recording: true)
        recorder.startRecording()
        print("Recording started...")
    }

    private func stopRecordingAndTranscribe() {
        isRecording = false
        updateMenubarIcon(recording: false)

        // No trailing delay — the tail-cutoff is fixed at the source by a small tap
        // buffer (see AudioRecorder), so the dropped partial buffer is ~10ms, not
        // ~85ms. Stop and transcribe immediately: zero added latency.
        guard let wavURL = recorder.stopRecording() else {
            print("Recording failed — no file produced")
            return
        }
        lastWavURL = wavURL   // kept on disk — recoverable via "Re-transcribe last" if the backend is down
        transcribeAndPaste(wavURL: wavURL)
    }

    // A transcription failure is now surfaced (no silent slow-fallback): flash an
    // amber warning icon for a few seconds. The WAV is on disk, so "Re-transcribe
    // last" recovers it once the backend is back.
    private func showFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "backend unavailable")?.withSymbolConfiguration(cfg) {
                img.isTemplate = false
                button.image = img
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.updateMenubarIcon(recording: false)
            }
        }
    }

    @objc private func reTranscribeLast() {
        guard let url = lastWavURL, FileManager.default.fileExists(atPath: url.path) else { return }
        transcribeAndPaste(wavURL: url)
    }

    @objc private func revealLastRecording() {
        guard let url = lastWavURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func transcribeAndPaste(wavURL: URL) {
        let url = URL(string: "http://localhost:8000/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Generous ceiling: a multi-minute recording on the slow local path can
        // take tens of seconds; remote is far faster. The headroom is harmless.
        request.timeoutInterval = 300

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let wavData: Data
        do {
            wavData = try Data(contentsOf: wavURL)
        } catch {
            print("Failed to read WAV file: \(error.localizedDescription)")
            return
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        print("Sending to transcription backend...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Transcription request failed: \(error.localizedDescription)")
                self?.showFailure()
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                print("Invalid response from backend")
                self?.showFailure()
                return
            }

            guard !text.isEmpty else {
                print("Transcription was empty (hallucination filtered)")
                return
            }
            print("Transcription: \(text)")
            DispatchQueue.main.async {
                self?.lastTranscription = text
                self?.pasteText(text)
            }
        }.resume()
    }

    private func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cgSessionEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let prev = previousContents {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController()
        }
        historyWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showRules() {
        if rulesPanel == nil { rulesPanel = RulesPanelController() }
        rulesPanel?.showPanel()
    }

    @objc private func showDictionary() {
        if dictionaryPanel == nil {
            dictionaryPanel = DictionaryPanelController()
        }
        dictionaryPanel?.showPanel()
    }

    @objc private func showLogs() {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice-to-Text/voice-to-text.log")
        NSWorkspace.shared.open(logPath)
    }

    private var backendFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice-to-Text/backend.txt")
    }

    // Every backend transcribes the whole recording in one shot on stop
    // (remote model server, or local whisper-cli).
    // Local-first: Parakeet on the GPU (MLX) or Neural Engine (ANE), with offline
    // whisper as the travel fallback. Remote Nemotron (lan/tailscale) retired —
    // local matches it on speed AND accuracy with no network tax.
    static let validBackends: Set<String> = ["parakeet"]

    private var currentBackend: String {
        let v = UserDefaults.standard.string(forKey: "WhisperBackend") ?? "parakeet"
        // Normalize away any stale value (old "tailscale"/"lan"/"nemotron") so a
        // leftover setting can't desync the app from the backend.
        return Self.validBackends.contains(v) ? v : "parakeet"
    }

    private func syncBackendFile() {
        try? currentBackend.write(to: backendFileURL, atomically: true, encoding: .utf8)
    }

    private func updateBackendCheckmarks() {
        let current = currentBackend
        for item in backendMenuItems {
            item.state = (item.representedObject as? String == current) ? .on : .off
        }
    }

    @objc private func setBackend(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: "WhisperBackend")
        syncBackendFile()
        updateBackendCheckmarks()
    }

    // Asks the localhost backend to probe its configured remote endpoint(s) and
    // shows the results. The app never knows remote topology — that lives in the
    // backend's config.json — so this works for any user's setup unchanged.
    @objc private func testWhisperServer() {
        let url = URL(string: "http://localhost:8000/backend-status")!
        URLSession.shared.dataTask(with: url) { data, _, err in
            var lines: [String] = []
            var mode = self.currentBackend
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                mode = obj["mode"] as? String ?? mode
                let remotes = obj["remotes"] as? [[String: Any]] ?? []
                if remotes.isEmpty {
                    lines.append("No remote server configured — local-only mode.\nAdd one in config.json (see README).")
                }
                for r in remotes {
                    let m = r["mode"] as? String ?? "?"
                    let ms = r["ms"] as? Int ?? 0
                    if (r["ok"] as? Bool) == true {
                        let code = r["status"] as? Int ?? 0
                        lines.append("\(m)\n  ✓ reachable (HTTP \(code)) in \(ms)ms")
                    } else {
                        let e = r["error"] as? String ?? "no response"
                        lines.append("\(m)\n  ✗ \(e) (\(ms)ms)")
                    }
                }
            } else {
                lines.append("✗ backend not reachable on localhost:8000\n  \(err?.localizedDescription ?? "no response")")
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Backend Status"
                alert.informativeText = lines.joined(separator: "\n\n")
                    + "\n\nCurrent backend: \(mode)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }.resume()
    }


    @objc private func restart() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", appBundlePath]
        task.launch()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - History Window

class HistoryWindowController: NSWindowController {
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var transcriptions: [[String: Any]] = []

    // Colors
    private let bgColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    private let cardColor = NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0)
    private let cardHoverColor = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
    private let textPrimary = NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1.0)
    private let textSecondary = NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1.0)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 300)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

        self.init(window: window)
        setupUI()
        loadHistory()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        loadHistory()
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = bgColor.cgColor

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0

        scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        container.addSubview(scrollView)
        window.contentView = container
    }

    func loadHistory() {
        let url = URL(string: "http://localhost:8000/history?limit=100")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                print("Failed to load history: \(error?.localizedDescription ?? "bad response")")
                return
            }
            DispatchQueue.main.async {
                self?.transcriptions = json
                self?.rebuildList()
            }
        }.resume()
    }

    private func rebuildList() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if transcriptions.isEmpty {
            let empty = NSTextField(labelWithString: "No transcriptions yet.")
            empty.font = NSFont.systemFont(ofSize: 15, weight: .light)
            empty.textColor = textSecondary
            empty.alignment = .center
            let wrapper = NSView()
            wrapper.addSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
                empty.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 60),
                empty.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -60),
            ])
            stackView.addArrangedSubview(wrapper)
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            wrapper.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return
        }

        for (index, item) in transcriptions.enumerated() {
            let card = makeCard(item: item, index: index)
            stackView.addArrangedSubview(card)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 16).isActive = true
            card.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16).isActive = true

            // Spacer between cards
            if index < transcriptions.count - 1 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
                stackView.addArrangedSubview(spacer)
                spacer.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                spacer.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            }
        }
    }

    private func makeCard(item: [String: Any], index: Int) -> NSView {
        let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeRaw = (item["created_at"] as? String) ?? ""
        let timeDisplay = formatTime(timeRaw)

        // Card container
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = cardColor.cgColor
        card.layer?.cornerRadius = 10

        // --- Top row: timestamp + copy button ---
        let timeLabel = NSTextField(labelWithString: timeDisplay)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = textSecondary

        let copyButton = NSButton(frame: .zero)
        if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            copyButton.image = img.withSymbolConfiguration(config)
        }
        copyButton.isBordered = false
        copyButton.contentTintColor = textSecondary
        copyButton.toolTip = "Copy to clipboard"
        copyButton.tag = index
        copyButton.target = self
        copyButton.action = #selector(copyRow(_:))

        // Hover effect on copy button
        let trackingArea = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: copyButton, userInfo: nil
        )
        copyButton.addTrackingArea(trackingArea)

        // --- Text content ---
        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        textField.textColor = textPrimary
        textField.isSelectable = true
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.allowsDefaultTighteningForTruncation = false

        // Line height via paragraph style
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 0
        let attributedString = NSMutableAttributedString(string: text)
        attributedString.addAttributes([
            .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
            .foregroundColor: textPrimary,
            .paragraphStyle: paragraphStyle,
        ], range: NSRange(location: 0, length: attributedString.length))
        textField.attributedStringValue = attributedString

        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping

        // --- Layout ---
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(timeLabel)
        card.addSubview(copyButton)
        card.addSubview(textField)

        var constraints = [
            // Time label: top-left
            timeLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            timeLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),

            // Copy button: top-right
            copyButton.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 28),

            // Text: below time, full width with generous margins
            textField.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 10),
            textField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ]

        constraints.append(
            textField.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        )

        NSLayoutConstraint.activate(constraints)

        return card
    }

    @objc private func copyRow(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < transcriptions.count else { return }

        if let text = transcriptions[index]["text"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            print("Copied: \(text)")

            // Animate to checkmark
            let original = sender.contentTintColor
            sender.contentTintColor = NSColor.systemGreen
            if let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied") {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                sender.image = img.withSymbolConfiguration(config)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                sender.contentTintColor = original
                if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
                    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    sender.image = img.withSymbolConfiguration(config)
                }
            }
        }
    }

    private func formatTime(_ isoString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: isoString) else { return isoString }

        let display = DateFormatter()
        display.timeZone = .current

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            display.dateFormat = "h:mm a"
            return "Today, " + display.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            display.dateFormat = "h:mm a"
            return "Yesterday, " + display.string(from: date)
        } else {
            display.dateFormat = "MMM d, h:mm a"
            return display.string(from: date)
        }
    }
}

// MARK: - Dictionary Panel

class DictionaryPanelController {
    private var panel: NSPanel!
    private var fromField: NSTextField!
    private var toField: NSTextField!
    private var entriesView: NSTextView!

    private var dictionaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice-to-Text/dictionary.json")
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Dictionary"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating

        setupUI()
    }

    private func setupUI() {
        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let entriesLabel = NSTextField(labelWithString: "Current entries:")
        entriesLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        entriesLabel.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        entriesView = NSTextView(frame: .zero)
        entriesView.isEditable = false
        entriesView.isSelectable = true
        entriesView.drawsBackground = false
        entriesView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        entriesView.textColor = .labelColor
        scroll.documentView = entriesView

        let fromLabel = NSTextField(labelWithString: "It hears:")
        fromLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fromLabel.textColor = .secondaryLabelColor

        fromField = NSTextField(frame: .zero)
        fromField.placeholderString = "e.g. whisper own"
        fromField.font = NSFont.systemFont(ofSize: 14)
        fromField.focusRingType = .none

        let toLabel = NSTextField(labelWithString: "Replace with:")
        toLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toLabel.textColor = .secondaryLabelColor

        toField = NSTextField(frame: .zero)
        toField.placeholderString = "e.g. WhisperOwn"
        toField.font = NSFont.systemFont(ofSize: 14)
        toField.focusRingType = .none

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        for view in [entriesLabel, scroll, fromLabel, fromField!, toLabel, toField!, saveButton, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            entriesLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            entriesLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: entriesLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 150),

            fromLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            fromLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            fromField.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 4),
            fromField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fromField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            toLabel.topAnchor.constraint(equalTo: fromField.bottomAnchor, constant: 12),
            toLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            toField.topAnchor.constraint(equalTo: toLabel.bottomAnchor, constant: 4),
            toField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            saveButton.topAnchor.constraint(equalTo: toField.bottomAnchor, constant: 16),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])

        panel.contentView = content
    }

    private func loadEntries() {
        var text = ""
        if let data = try? Data(contentsOf: dictionaryURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (k, v) in dict.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) where !k.hasPrefix("_") {
                text += "\(k)  →  \(v)\n"
            }
        }
        entriesView.string = text.isEmpty ? "(no entries yet)" : text
    }

    func showPanel() {
        loadEntries()
        fromField.stringValue = ""
        toField.stringValue = ""
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(fromField)
    }

    @objc private func cancel() {
        panel.close()
    }

    @objc private func save() {
        let from = fromField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = toField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return }

        var dictionary: [String: String] = [:]
        if let data = try? Data(contentsOf: dictionaryURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dictionary = existing
        }

        dictionary[from] = to

        if let jsonData = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: dictionaryURL)
            print("Dictionary updated: \"\(from)\" -> \"\(to)\"")
        }

        panel.close()
    }
}

// MARK: - Audio Recorder

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var converter: AVAudioConverter?
    private var tapInstalled = false

    // Whisper was trained on 16 kHz. Record natively at that rate so the
    // backend has no encode pass and recordings are 3x smaller on disk.
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

        // On-disk format: 16 kHz mono int16 PCM.
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

    func stopRecording() -> URL? {
        // Close the file FIRST so any AVAudioFile-buffered audio flushes to
        // disk even if later cleanup throws. (Previous bug: an NSException in
        // removeTap escaped before audioFile=nil ran, leaving recordings as
        // 4 KB header-only files with no audio data.)
        let resultURL = outputURL
        audioFile = nil

        if tapInstalled, let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        return resultURL
    }

    private func getDataDirectory() -> URL {
        let projectData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice-to-Text/recordings")
        try? FileManager.default.createDirectory(at: projectData, withIntermediateDirectories: true)
        return projectData
    }
}

// Read-only viewer of the active cleanup rules (fetched from the backend's /rules),
// grouped into sections. Editing is deliberately NOT here — the Copy-prompt button
// hands your agent a ready prompt; the agent edits backend/postprocess.js.
class RulesPanelController {
    private var panel: NSPanel!
    private var textView: NSTextView!
    private var copyButton: NSButton!

    private let prompt = "WhisperOwn's dictation cleanup runs deterministic regex in backend/postprocess.js, each rule documented in docs/POSTPROCESS.md. I want to change a cleanup rule: <describe the change>. Edit the rule, add a fixture to backend/postprocess.test.js covering BOTH the fix AND a near-miss it must not touch, then run `node backend/postprocess.test.js` and confirm all pass."

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered, defer: false)
        panel.title = "Cleanup Rules"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating

        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = textView

        let footer = NSTextField(labelWithString: "Add or change a rule →")
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor

        copyButton = NSButton(title: "Copy prompt for your agent", target: self, action: #selector(copyPrompt))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small

        for v in [scroll, footer, copyButton!] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
    }

    func showPanel() {
        loadRules()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copyButton.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyButton.title = "Copy prompt for your agent"
        }
    }

    private func loadRules() {
        textView.string = "Loading…"
        guard let url = URL(string: "http://localhost:8000/rules") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    self.textView.textStorage?.setAttributedString(self.render(arr))
                } else {
                    self.textView.string = "(couldn't reach the backend — is it running?)"
                }
            }
        }.resume()
    }

    private func render(_ rules: [[String: String]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let descFont = NSFont.systemFont(ofSize: 12)
        let descPara = NSMutableParagraphStyle(); descPara.paragraphSpacing = 9; descPara.lineSpacing = 1
        var lastSection = ""
        for r in rules {
            let section = r["section"] ?? ""
            if section != lastSection {
                out.append(NSAttributedString(string: (lastSection.isEmpty ? "" : "\n") + section.uppercased() + "\n",
                    attributes: [.font: headFont, .foregroundColor: NSColor.systemOrange, .kern: 0.8]))
                lastSection = section
            }
            out.append(NSAttributedString(string: (r["name"] ?? "") + "\n",
                attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor]))
            out.append(NSAttributedString(string: (r["desc"] ?? "") + "\n",
                attributes: [.font: descFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: descPara]))
        }
        return out
    }
}

// MARK: - Onboarding / Permissions Guide
//
// A guided first-run window. Shown only when microphone or accessibility is
// missing. Each OS prompt fires one at a time, only when the user clicks its
// step — no more firing both system dialogs at launch with no context. Statuses
// flip to a green check live (a poll), so granting is visible "click → ✓".

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let onDone: () -> Void
    private var window: NSWindow!
    private var pollTimer: Timer?
    private var finished = false

    private var micIcon: NSImageView!
    private var axIcon: NSImageView!
    private var globeIcon: NSImageView!
    private var micButton: NSButton!
    private var axButton: NSButton!
    private var globeButton: NSButton!
    private var finishButton: NSButton!

    private let rowWidth: CGFloat = 412

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init()
        buildWindow()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
        refresh()
        startPolling()
    }

    // MARK: build

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 464, height: 440),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "WhisperOwn"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)

        root.addArrangedSubview(label("WhisperOwn", .systemFont(ofSize: 22, weight: .bold), .labelColor))
        root.addArrangedSubview(label("A quick permissions guide. Grant each one below —\nWhisperOwn walks you through it, one step at a time.",
                                      .systemFont(ofSize: 13), .secondaryLabelColor))
        root.addArrangedSubview(separator())

        micIcon = statusIcon()
        micButton = actionButton("Allow Microphone", #selector(micTapped))
        root.addArrangedSubview(stepRow(micIcon, "Microphone",
            "So WhisperOwn can hear you.", micButton))

        axIcon = statusIcon()
        axButton = actionButton("Open Accessibility…", #selector(axTapped))
        root.addArrangedSubview(stepRow(axIcon, "Accessibility",
            "Lets WhisperOwn see the Globe key and paste for you.\nToggle WhisperOwn on in the list that opens.", axButton))

        globeIcon = statusIcon()
        globeButton = actionButton("Open Keyboard…", #selector(globeTapped))
        root.addArrangedSubview(stepRow(globeIcon, "Free up the Globe key",
            "In Keyboard settings, set “Press 🌐 key to” → “Do\nNothing”. Detected automatically.", globeButton))

        root.addArrangedSubview(separator())

        finishButton = NSButton(title: "Finish", target: self, action: #selector(finishTapped))
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, finishButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        root.addArrangedSubview(footer)

        w.contentView = root
        root.layoutSubtreeIfNeeded()
        w.setContentSize(root.fittingSize)
        w.center()
        window = w
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font; l.textColor = color
        l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        return b
    }

    private func statusIcon() -> NSImageView {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return iv
    }

    private func actionButton(_ t: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: action)
        b.bezelStyle = .rounded
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    private func stepRow(_ icon: NSImageView, _ title: String, _ desc: String, _ button: NSButton) -> NSView {
        let name = label(title, .systemFont(ofSize: 14, weight: .semibold), .labelColor)
        let d = label(desc, .systemFont(ofSize: 12), .secondaryLabelColor)
        let text = NSStackView(views: [name, d])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, button])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        return row
    }

    // MARK: status

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = AXIsProcessTrusted()
        let globeOK = globeKeyIsFree()
        setIcon(micIcon, micOK); setIcon(axIcon, axOK); setIcon(globeIcon, globeOK)
        micButton.isEnabled = !micOK; if micOK { micButton.title = "Granted" }
        axButton.isEnabled = !axOK; if axOK { axButton.title = "Granted" }
        globeButton.isEnabled = !globeOK; if globeOK { globeButton.title = "Set" }
        else { globeButton.title = "Open Keyboard…" }
        finishButton.isEnabled = micOK && axOK
    }

    // Reads macOS's "Press 🌐 key to" setting — 0 = "Do Nothing", which hands the
    // key to WhisperOwn. Uses a fresh `defaults read` subprocess rather than the
    // CFPreferences API: CFPreferences caches another process's domain, so a change
    // made in System Settings wasn't seen until forced re-entry. A new subprocess
    // has no cache and always reads the current value.
    private func globeKeyIsFree() -> Bool {
        let p = Process()
        p.launchPath = "/usr/bin/defaults"
        p.arguments = ["read", "com.apple.HIToolbox", "AppleFnUsageType"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s == "0"
    }

    private func setIcon(_ iv: NSImageView, _ done: Bool) {
        let name = done ? "checkmark.circle.fill" : "circle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [done ? .systemGreen : .tertiaryLabelColor]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = false
        iv.image = img
    }

    // MARK: actions

    @objc private func micTapped() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refresh() }
            }
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default: break
        }
    }

    @objc private func axTapped() {
        // Open the Accessibility pane directly — NO prompt dialog. The prompt API
        // triggers a second OS window we can't suppress; the pane alone is one
        // window. WhisperOwn is already in the list (registered by the tap attempt
        // at launch), so the user just toggles it and this row flips green live.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func globeTapped() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    @objc private func finishTapped() { finish() }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        window.orderOut(nil)
        onDone()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
