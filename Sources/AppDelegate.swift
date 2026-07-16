import Cocoa
import AVFoundation
import Carbon.HIToolbox

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
    private var onboarding: OnboardingWindowController?
    private var hotkeyArmed = false

    // Hard cap on a single recording. A forgotten or stuck recording otherwise
    // grows without bound (16kHz mono int16 is ~115 MB/hr). At the cap we stop and
    // KEEP the file (recoverable via "Re-transcribe last"), but don't auto-paste an
    // hour of text nobody asked for.
    private var recordingCap: DispatchWorkItem?
    private static let maxRecordingSeconds: TimeInterval = 3600

    private var appBundlePath: String {
        return Bundle.main.bundlePath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // autosaveName + isVisible: macOS 26 (Tahoe) hides unnamed status items
        // in a Control Center-managed registry. Named items survive.
        statusItem.autosaveName = "WhisperOwn"
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
        menu.addItem(NSMenuItem(title: "Permissions Guide…", action: #selector(showPermissionsGuide), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Edit menu so Cmd-X/C/V/A work in the Dictionary text fields. An accessory
        // app has no visible menu bar, but the key-equivalents still route to the
        // first responder — without this, paste into a text field does nothing.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        let logPath = Paths.log.path

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
        let cap = DispatchWorkItem { [weak self] in self?.stopRecordingAtCap() }
        recordingCap = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds, execute: cap)
        print("Recording started...")
    }

    private func stopRecordingAndTranscribe() {
        recordingCap?.cancel()
        recordingCap = nil
        isRecording = false
        updateMenubarIcon(recording: false)
        // Stop and transcribe immediately — zero added latency. The tail is kept by
        // flushing in-flight buffers before closing the file (see AudioRecorder).
        guard let wavURL = recorder.stopRecording() else {
            print("Recording failed — no file produced")
            return
        }
        lastWavURL = wavURL   // on disk — recoverable via "Re-transcribe last"
        transcribeAndPaste(wavURL: wavURL)
    }

    // The 1-hour cap fired: stop and save, but deliberately do NOT transcribe/paste
    // (an hour in almost always means a forgotten recording). The WAV stays on disk.
    private func stopRecordingAtCap() {
        guard isRecording else { return }
        recordingCap = nil
        isRecording = false
        updateMenubarIcon(recording: false)
        if let wavURL = recorder.stopRecording() {
            lastWavURL = wavURL
        }
        print("Recording hit the 1-hour cap — stopped and saved (not auto-transcribed).")
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
        // A multi-minute recording can take tens of seconds to transcribe; this
        // ceiling is generous headroom.
        request.timeoutInterval = 300

        // Backend runs on the same machine and reads from the same recordings
        // folder, so we hand it the path we already wrote instead of re-uploading
        // the bytes for it to save a second copy. One file on disk, and it's cheap
        // for long recordings (no multi-MB HTTP body).
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": wavURL.path])

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

    // The last few characters before the insertion point in the focused text field,
    // via the Accessibility API (already granted). Returns nil when the app doesn't
    // expose it (some terminals / web / Electron views) — the caller then pastes
    // plainly. Reads at most ~16 chars, never the whole document.
    private func contextBeforeCursor() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              CFGetTypeID(focused!) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &sel) else { return nil }
        let cursor = sel.location
        if cursor <= 0 { return "" }

        let start = max(0, cursor - 16)
        var wanted = CFRange(location: start, length: cursor - start)
        guard let wantedVal = AXValueCreate(.cfRange, &wanted) else { return nil }
        var strRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, wantedVal, &strRef) == .success,
           let s = strRef as? String {
            return s
        }
        return nil
    }

    private func pasteText(_ text: String) {
        // `text` carries a trailing space (so a single dictation ends ready-to-type)
        // and, by design, no trailing period. Look at what's just before the cursor:
        // if the previous text ends on a word with no sentence punctuation (e.g. the
        // last dictation), close it with a period so chained dictations don't run on.
        // The period is inserted RIGHT after the word, so any trailing space left by
        // the previous dictation is deleted first (backspaces).
        var toPaste = text
        var backspaces = 0
        if let before = contextBeforeCursor() {
            let wsSuffix = String(before.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\n" }.reversed())
            let trimmed = String(before.dropLast(wsSuffix.count))
            if trimmed.isEmpty || wsSuffix.contains("\n") {
                // fresh field or a new line the user made — no period, paste as-is
            } else if let last = trimmed.last {
                if ".!?".contains(last) {
                    if wsSuffix.isEmpty { toPaste = " " + text }
                } else if last.isLetter || last.isNumber {
                    toPaste = ". " + text
                    backspaces = wsSuffix.count
                } else if wsSuffix.isEmpty {
                    toPaste = " " + text
                }
            }
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(toPaste, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            // Delete the previous dictation's trailing space(s) so an inserted period
            // hugs the word ("there. how", not "there . how").
            for _ in 0..<backspaces {
                CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)?.post(tap: .cgSessionEventTap)
                CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)?.post(tap: .cgSessionEventTap)
            }
            let paste = {
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
            // Paste only AFTER the deletions register — a same-tick paste can land
            // before the backspaces, leaving the space in front of the period.
            if backspaces > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: paste)
            } else {
                paste()
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

