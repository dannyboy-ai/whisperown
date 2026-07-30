import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem!
    private var recorder: AudioRecorder!
    private let transcriber = FluidTranscriber()
    private var isRecording = false
    private var globePressed = false
    private var lastTranscription: String?
    private var lastWavURL: URL?
    private var historyWindow: HistoryWindowController?
    private var dictionaryPanel: DictionaryPanelController?
    private var rulesPanel: RulesPanelController?
    private var onboarding: OnboardingWindowController?
    private var modelWindow: ModelDownloadWindowController?
    private var performancePanel: PerformancePanelController?
    private var modelReady = false
    private var modelState: ModelPreparationState = .preparing
    private var didPresentPermissions = false
    private var openAtLoginItem: NSMenuItem?
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
        menu.addItem(NSMenuItem(title: "Speech Model…", action: #selector(showSpeechModel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Performance…", action: #selector(showPerformance), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Permissions Guide…", action: #selector(showPermissionsGuide), keyEquivalent: ""))
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        openAtLoginItem = loginItem
        updateOpenAtLoginItem()
        menu.addItem(loginItem)
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
        _ = HistoryStore.shared

        let modelWasInstalled = FluidTranscriber.modelIsInstalled
        startModelPreparation(showWindow: !modelWasInstalled)

        // Always attempt the tap. When trusted it arms the Globe key; when NOT
        // trusted the failed attempt still registers WhisperOwn in Accessibility.
        setupHotKeyMonitoring()

        if modelWasInstalled {
            presentPermissionsIfNeeded()
        }
    }
    private func startModelPreparation(showWindow: Bool) {
        modelReady = false
        modelState = .preparing
        if showWindow {
            Task { @MainActor [weak self] in self?.showSpeechModel() }
        }
        let transcriber = transcriber
        Task { [weak self] in
            guard let delegate = self else { return }
            do {
                try await transcriber.prepare { state in
                    Task { @MainActor in
                        delegate.handleModelPreparation(state)
                    }
                }
            } catch is CancellationError {
                // The state callback has already changed the window to Resume.
            } catch {
                print("Fluid Unified preparation failed: \(error)")
            }
        }
    }

    @MainActor
    private func handleModelPreparation(_ state: ModelPreparationState) {
        modelState = state
        modelWindow?.update(state)
        guard case .ready = state else { return }
        modelReady = true
        if modelWindow?.window?.isVisible == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.modelWindow?.close()
                self?.presentPermissionsIfNeeded()
            }
        } else {
            presentPermissionsIfNeeded()
        }
        if didPresentPermissions,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           AXIsProcessTrusted() {
            print("WhisperOwn ready. Press Globe (Fn) to start/stop recording. Ctrl+Cmd+V to re-paste.")
        }
    }

    private func presentPermissionsIfNeeded() {
        guard !didPresentPermissions else { return }
        didPresentPermissions = true
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = AXIsProcessTrusted()
        if micOK && axOK {
            if modelReady {
                print("WhisperOwn ready. Press Globe (Fn) to start/stop recording. Ctrl+Cmd+V to re-paste.")
            } else {
                print("Permissions ready; local speech model is loading.")
            }
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

        // Keep local diagnostics crash-safe and immediately readable.
        freopen(logPath, "a", stderr)
        freopen(logPath, "a", stdout)
        setbuf(stderr, nil)
        setbuf(stdout, nil)
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
        guard modelReady else {
            print("Recording unavailable until the speech model is ready")
            Task { @MainActor [weak self] in self?.showSpeechModel() }
            return
        }
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
        let stopRequested = ProcessInfo.processInfo.systemUptime
        // Stop and transcribe the retained 16 kHz samples immediately. The WAV is
        // finalized at the same time and remains available for recovery/history.
        guard let recording = recorder.stopRecording() else {
            print("Recording failed — no audio produced")
            return
        }
        let audioFinalized = ProcessInfo.processInfo.systemUptime
        lastWavURL = recording.url
        transcribeAndPaste(
            recording: recording,
            stopRequested: stopRequested,
            audioFinalizeMS: milliseconds(from: stopRequested, to: audioFinalized)
        )
    }

    // The 1-hour cap fired: stop and save, but deliberately do NOT transcribe/paste
    // (an hour in almost always means a forgotten recording). The WAV stays on disk.
    private func stopRecordingAtCap() {
        guard isRecording else { return }
        recordingCap = nil
        isRecording = false
        updateMenubarIcon(recording: false)
        if let recording = recorder.stopRecording() {
            lastWavURL = recording.url
        }
        print("Recording hit the 1-hour cap — stopped and saved (not auto-transcribed).")
    }

    // A transcription failure is surfaced by flashing an amber warning icon. The
    // WAV stays on disk, so "Re-transcribe last" remains a recovery path.
    private func showFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "transcription failed")?.withSymbolConfiguration(cfg) {
                img.isTemplate = false
                button.image = img
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.updateMenubarIcon(recording: false)
            }
        }
    }

    @objc private func reTranscribeLast() {
        guard modelReady,
              let url = lastWavURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        transcribeAndPaste(wavURL: url)
    }

    @objc private func revealLastRecording() {
        guard let url = lastWavURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func transcribeAndPaste(
        recording: AudioRecording,
        stopRequested: TimeInterval,
        audioFinalizeMS: Int
    ) {
        let transcriber = transcriber
        Task { [weak self] in
            let inferenceStarted = ProcessInfo.processInfo.systemUptime
            do {
                let raw = try await transcriber.transcribe(recording.samples)
                let inferenceFinished = ProcessInfo.processInfo.systemUptime
                await self?.finishTranscription(
                    raw: raw,
                    wavURL: recording.url,
                    audioDurationMS: recording.durationMilliseconds,
                    stopRequested: stopRequested,
                    audioFinalizeMS: audioFinalizeMS,
                    inferenceMS: self?.milliseconds(from: inferenceStarted, to: inferenceFinished) ?? 0
                )
            } catch {
                print("Fluid Unified transcription failed: \(error)")
                self?.showFailure()
            }
        }
    }

    private func transcribeAndPaste(wavURL: URL) {
        let started = ProcessInfo.processInfo.systemUptime
        let transcriber = transcriber
        Task { [weak self] in
            do {
                let raw = try await transcriber.transcribe(wavURL)
                let inferenceFinished = ProcessInfo.processInfo.systemUptime
                await self?.finishTranscription(
                    raw: raw,
                    wavURL: wavURL,
                    audioDurationMS: 0,
                    stopRequested: started,
                    audioFinalizeMS: 0,
                    inferenceMS: self?.milliseconds(from: started, to: inferenceFinished) ?? 0
                )
            } catch {
                print("Fluid Unified transcription failed: \(error)")
                self?.showFailure()
            }
        }
    }

    private func finishTranscription(
        raw: String,
        wavURL: URL,
        audioDurationMS: Int,
        stopRequested: TimeInterval,
        audioFinalizeMS: Int,
        inferenceMS: Int
    ) async {
        let cleanupStarted = ProcessInfo.processInfo.systemUptime
        let text = Postprocessor.process(raw)
        do {
            let rowID = try await HistoryStore.shared.save(
                audioPath: wavURL.path,
                text: text,
                durationMilliseconds: audioDurationMS == 0 ? nil : audioDurationMS,
                source: "fluid-unified"
            )
            let cleanupFinished = ProcessInfo.processInfo.systemUptime
            let cleanupAndHistoryMS = milliseconds(from: cleanupStarted, to: cleanupFinished)

            guard !text.isEmpty else {
                print("Transcription was empty (noise filtered)")
                await recordTiming(
                    audioDurationMS: audioDurationMS,
                    audioFinalizeMS: audioFinalizeMS,
                    inferenceMS: inferenceMS,
                    cleanupAndHistoryMS: cleanupAndHistoryMS,
                    pasteIssueMS: 0,
                    stopRequested: stopRequested
                )
                return
            }

            print("Transcription: \(text) (id=\(rowID))")
            let pasteStarted = ProcessInfo.processInfo.systemUptime
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.lastTranscription = text
                    self.pasteText(text) {
                        continuation.resume()
                    }
                }
            }
            let pasteIssued = ProcessInfo.processInfo.systemUptime
            await recordTiming(
                audioDurationMS: audioDurationMS,
                audioFinalizeMS: audioFinalizeMS,
                inferenceMS: inferenceMS,
                cleanupAndHistoryMS: cleanupAndHistoryMS,
                pasteIssueMS: milliseconds(from: pasteStarted, to: pasteIssued),
                stopRequested: stopRequested
            )
        } catch {
            print("Could not save transcription history: \(error.localizedDescription)")
            showFailure()
        }
    }

    private func recordTiming(
        audioDurationMS: Int,
        audioFinalizeMS: Int,
        inferenceMS: Int,
        cleanupAndHistoryMS: Int,
        pasteIssueMS: Int,
        stopRequested: TimeInterval
    ) async {
        let timing = DictationTiming(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            audioDurationMS: audioDurationMS,
            audioFinalizeMS: audioFinalizeMS,
            inferenceMS: inferenceMS,
            cleanupAndHistoryMS: cleanupAndHistoryMS,
            pasteIssueMS: pasteIssueMS,
            totalMS: milliseconds(
                from: stopRequested,
                to: ProcessInfo.processInfo.systemUptime
            )
        )
        await TimingStore.shared.record(timing)
    }

    private func milliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int((end - start) * 1_000)
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

    private func pasteText(_ text: String, onIssued: (() -> Void)? = nil) {
        // `text` has no trailing space and, by design, no trailing period. The
        // separator is decided from whatever sits right before the cursor, so a
        // chained dictation closes the previous one ("there. how") instead of
        // running on.
        //
        // Nothing is ever deleted to achieve that. An earlier version emitted a
        // trailing space and then backspaced it away to make the period hug the
        // word — but a synthesized delete that loses the race leaves "there . how".
        // Emitting no trailing space removes the need for the delete entirely.
        var toPaste = text
        if let before = contextBeforeCursor() {
            if let last = before.last {
                if last == " " || last == "\t" || last == "\n" {
                    // already separated (or a fresh line) — paste as-is
                } else if last.isLetter || last.isNumber {
                    toPaste = ". " + text   // close the previous dictation
                } else {
                    toPaste = " " + text    // after . ! ? , etc.
                }
            }
            // before.isEmpty -> start of the field, paste as-is
        } else {
            // No accessibility context available (some apps expose none). Fall back
            // to a trailing space so chained dictations still don't run together.
            toPaste = text + " "
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(toPaste, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cgSessionEventTap)
            onIssued?()
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
    @MainActor
    @objc private func showSpeechModel() {
        if modelWindow == nil {
            modelWindow = ModelDownloadWindowController(
                onRetry: { [weak self] in
                    self?.startModelPreparation(showWindow: false)
                },
                onCancel: { [weak self] in
                    guard let self else { return }
                    Task { await self.transcriber.cancelPreparation() }
                }
            )
        }
        modelWindow?.update(modelReady ? .ready : modelState)
        modelWindow?.show()
    }

    @objc private func showPerformance() {
        if performancePanel == nil {
            performancePanel = PerformancePanelController()
        }
        performancePanel?.showPanel()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateOpenAtLoginItem()
        } catch {
            print("Could not update Open at Login: \(error.localizedDescription)")
            showFailure()
        }
    }

    private func updateOpenAtLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            openAtLoginItem?.state = .on
            openAtLoginItem?.toolTip = nil
        case .requiresApproval:
            openAtLoginItem?.state = .mixed
            openAtLoginItem?.toolTip = "Enable WhisperOwn in System Settings → General → Login Items"
        default:
            openAtLoginItem?.state = .off
            openAtLoginItem?.toolTip = nil
        }
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

