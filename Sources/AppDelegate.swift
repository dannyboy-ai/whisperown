import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

struct DictationInsertion: Equatable {
    let pasteText: String
    let typePeriodBeforePaste: Bool
}

enum DictationJoiner {
    static func joining(
        _ text: String,
        contextBeforeCursor: String?,
        priorDictation: String?
    ) -> DictationInsertion {
        guard !text.isEmpty else {
            return DictationInsertion(pasteText: "", typePeriodBeforePaste: false)
        }
        if let last = contextBeforeCursor?.last {
            return DictationInsertion(
                pasteText: separator(after: last) + text,
                typePeriodBeforePaste: false
            )
        }
        // Some terminal accessibility trees claim the selection is at offset zero
        // even while their TUI input contains text. CMUX renders a period included
        // in the clipboard payload as " .", so type it separately and paste only
        // the leading space plus transcript.
        guard let last = priorDictation?.last, !last.isWhitespace else {
            return DictationInsertion(pasteText: text, typePeriodBeforePaste: false)
        }
        return DictationInsertion(
            pasteText: " " + text,
            typePeriodBeforePaste: last.isLetter || last.isNumber
        )
    }

    private static func separator(after character: Character) -> String {
        if character.isWhitespace {
            return ""
        }
        if character.isLetter || character.isNumber {
            return ". "
        }
        return " "
    }
}

private struct FocusedPasteContext {
    let processIdentifier: pid_t?
    let textBeforeCursor: String?
}

private struct PendingPaste {
    let text: String
    let onIssued: (() -> Void)?
}

enum PasteJoinEventFilter {
    static func isGlobeKey(_ keyCode: Int64) -> Bool {
        keyCode == 179
    }

    static func mouseChangedProcess(previous: pid_t?, current: pid_t?) -> Bool {
        guard let previous else { return false }
        return current != previous
    }

    static func isExpectedSyntheticPaste(
        keyCode: Int64,
        hasCommand: Bool,
        hasControl: Bool,
        markerMatches: Bool,
        now: TimeInterval,
        fallbackDeadline: TimeInterval
    ) -> Bool {
        if markerMatches {
            return true
        }
        return keyCode == Int64(kVK_ANSI_V)
            && hasCommand
            && !hasControl
            && now <= fallbackDeadline
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem!
    private var recorder: AudioRecorder!
    private let transcriber = FluidTranscriber()
    private var isRecording = false
    private var globePressed = false
    private var lastTranscription: String?
    private var lastWavURL: URL?
    private var historyWindow: HistoryWindowController?
    private var dictionaryWindow: DictionaryWindowController?
    private var cleanupWindow: CleanupWindowController?
    private var aboutWindow: AboutWindowController?
    private var onboarding: OnboardingWindowController?
    private var modelWindow: ModelDownloadWindowController?
    private var practiceWindow: PracticeWindowController?
    private var practiceReveal: MenuRevealWindowController?
    private var performancePanel: PerformancePanelController?
    private var modelReady = false
    private var modelState: ModelPreparationState = .preparing
    private var didPresentPermissions = false
    private var openAtLoginItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?
    private var pasteLastItem: NSMenuItem?
    private var retryLastItem: NSMenuItem?
    private var revealLastItem: NSMenuItem?
    private var hotkeyArmed = false
    private var lastFailedHistoryID: Int64?
    private var lastAudioDurationMilliseconds: Int?
    private var pendingPastes: [PendingPaste] = []
    private var pasteIsInFlight = false
    private var pasteboardStringBeforeSequence: String?
    private var pasteboardSnapshotTaken = false
    private var pasteboardRestore: DispatchWorkItem?
    private var lastPasteProcessIdentifier: pid_t?
    private var lastPastedDictation: String?
    private static let syntheticPasteMarker: Int64 = 0x574F5041535445
    private var syntheticPasteFallbackDeadline: TimeInterval = 0
    private static let practicePendingKey = "onboarding.practicePending"

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
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: "WhisperOwn", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let status = NSMenuItem(title: "Checking speech model…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        let pasteItem = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(rePasteLastTranscription),
            keyEquivalent: "v"
        )
        pasteItem.keyEquivalentModifierMask = [.control, .command]
        pasteItem.isEnabled = false
        pasteLastItem = pasteItem
        menu.addItem(pasteItem)
        menu.addItem(NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dictionary…", action: #selector(showDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Cleanup…", action: #selector(showCleanup), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        openAtLoginItem = loginItem
        updateOpenAtLoginItem()
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Getting Started…", action: #selector(showPermissionsGuide), keyEquivalent: ""))

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let advancedMenu = NSMenu(title: "Advanced")
        advancedMenu.autoenablesItems = false
        let retryItem = NSMenuItem(
            title: "Retry Failed Recording",
            action: #selector(reTranscribeLast),
            keyEquivalent: ""
        )
        retryItem.isEnabled = false
        retryLastItem = retryItem
        advancedMenu.addItem(retryItem)
        let revealItem = NSMenuItem(
            title: "Reveal Latest Recording in Finder",
            action: #selector(revealLastRecording),
            keyEquivalent: ""
        )
        revealItem.isEnabled = false
        revealLastItem = revealItem
        advancedMenu.addItem(revealItem)
        advancedMenu.addItem(NSMenuItem.separator())
        advancedMenu.addItem(NSMenuItem(title: "Speech Model Info…", action: #selector(showSpeechModel), keyEquivalent: ""))
        advancedMenu.addItem(NSMenuItem(title: "Performance…", action: #selector(showPerformance), keyEquivalent: ""))
        advancedItem.submenu = advancedMenu
        menu.addItem(advancedItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About WhisperOwn", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit WhisperOwn", action: #selector(quit), keyEquivalent: "q"))
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
        setMenuStatus("Checking speech model…")
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
        switch state {
        case .preparing:
            setMenuStatus("Checking speech model…")
        case .progress:
            setMenuStatus("Downloading speech model…")
        case .failed:
            setMenuStatus("Speech model unavailable")
        case .cancelled:
            setMenuStatus("Speech model download paused")
        case .ready:
            break
        }
        guard case .ready = state else { return }
        modelReady = true
        updateRecoveryItems()
        if modelWindow?.window?.isVisible == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.modelWindow?.close()
                self?.presentPermissionsIfNeeded()
            }
        } else {
            presentPermissionsIfNeeded()
        }
        refreshReadyStatus()
        presentPracticeIfNeeded()
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
            refreshReadyStatus()
            if modelReady {
                print("WhisperOwn ready. Press Globe (Fn) to start/stop recording. Ctrl+Cmd+V to re-paste.")
            } else {
                print("Permissions ready; local speech model is loading.")
            }
            presentPracticeIfNeeded()
        } else {
            setMenuStatus("Setup required")
            print("First-run: missing \(micOK ? "" : "microphone ")\(axOK ? "" : "accessibility ")— opening Permissions Guide")
            showPermissionsGuide()
        }
    }

    @objc private func showPermissionsGuide() {
        if let existing = onboarding { existing.show(); return }
        // An accessory (menubar-only) app can't normally show a focused window;
        // flip to a regular app for the duration of the guide, then flip back.
        NSApp.setActivationPolicy(.regular)
        let controller = OnboardingWindowController(onDone: { [weak self] startPractice in
            guard let self else { return }
            self.onboarding = nil
            NSApp.setActivationPolicy(.accessory)

            guard startPractice else { return }
            UserDefaults.standard.set(true, forKey: Self.practicePendingKey)

            // A CGEvent tap can't be armed in-process after Accessibility is
            // granted. Relaunch once, then resume directly in the live practice.
            if AXIsProcessTrusted() && !self.hotkeyArmed {
                self.restart()
                return
            }
            self.presentPracticeIfNeeded()
        })
        onboarding = controller
        controller.show()
    }

    private func presentPracticeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.practicePendingKey),
              modelReady,
              hotkeyArmed,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              AXIsProcessTrusted()
        else { return }

        if let existing = practiceWindow {
            existing.show()
            return
        }

        NSApp.setActivationPolicy(.regular)
        let controller = PracticeWindowController(
            onRevealMenu: { [weak self] in self?.showPracticeMenuReveal() },
            onCancel: { [weak self] in self?.finishPractice() }
        )
        practiceWindow = controller
        controller.show()
    }

    private func showPracticeMenuReveal() {
        guard let button = statusItem.button else {
            finishPractice()
            return
        }

        let reveal = MenuRevealWindowController(
            onDone: { [weak self] in self?.finishPractice() }
        )
        practiceReveal = reveal
        reveal.show(below: button)
    }

    private func finishPractice() {
        UserDefaults.standard.removeObject(forKey: Self.practicePendingKey)
        practiceReveal?.close()
        practiceReveal = nil
        practiceWindow = nil
        NSApp.setActivationPolicy(.accessory)
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

    private func setMenuStatus(_ status: String) {
        statusMenuItem?.title = status
    }

    private func refreshReadyStatus() {
        guard modelReady else { return }
        let microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard microphoneReady, AXIsProcessTrusted() else {
            setMenuStatus("Setup required")
            return
        }
        setMenuStatus("Ready")
        updateMenubarIcon(recording: false)
    }

    private func updateRecoveryItems() {
        let recordingExists = lastWavURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        retryLastItem?.isEnabled = modelReady && recordingExists && lastFailedHistoryID != nil
        revealLastItem?.isEnabled = recordingExists
    }

    private func setupHotKeyMonitoring() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
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
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            validatePasteTargetAfterMouseEvent()
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let hasCtrl = flags.contains(.maskControl)
            let hasCmd = flags.contains(.maskCommand)
            let noShift = !flags.contains(.maskShift)
            let noAlt = !flags.contains(.maskAlternate)
            let markerMatches = event.getIntegerValueField(.eventSourceUserData)
                == Self.syntheticPasteMarker
            // Modern Apple keyboards also emit a key-down event with code 179 for
            // Globe. The flagsChanged path below owns that key; it is not text input
            // and must not clear the context between consecutive dictations.
            if PasteJoinEventFilter.isGlobeKey(keyCode) {
                return Unmanaged.passRetained(event)
            }

            if PasteJoinEventFilter.isExpectedSyntheticPaste(
                keyCode: keyCode,
                hasCommand: hasCmd,
                hasControl: hasCtrl,
                markerMatches: markerMatches,
                now: ProcessInfo.processInfo.systemUptime,
                fallbackDeadline: syntheticPasteFallbackDeadline
            ) {
                return Unmanaged.passRetained(event)
            }

            if keyCode == Int64(kVK_ANSI_V) && hasCtrl && hasCmd && noShift && noAlt {
                DispatchQueue.main.async { self.rePasteLastTranscription() }
                return nil
            }
            resetPasteJoinState(reason: "key-\(keyCode)")
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

    @objc private func rePasteLastTranscription() {
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
        setMenuStatus("Recording…")
        updateMenubarIcon(recording: true)
        recorder.startRecording()
        practiceWindow?.recordingDidStart()
        let cap = DispatchWorkItem { [weak self] in self?.stopRecordingAtCap() }
        recordingCap = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds, execute: cap)
        print("Recording started...")
    }

    private func stopRecordingAndTranscribe() {
        recordingCap?.cancel()
        recordingCap = nil
        isRecording = false
        setMenuStatus("Transcribing…")
        updateMenubarIcon(recording: false)
        let stopRequested = ProcessInfo.processInfo.systemUptime
        // Stop and transcribe the retained 16 kHz samples immediately. The WAV is
        // finalized at the same time and remains available for recovery/history.
        guard let recording = recorder.stopRecording() else {
            print("Recording failed — no audio produced")
            practiceWindow?.transcriptionDidFail()
            return
        }
        practiceWindow?.transcriptionDidStart()
        let audioFinalized = ProcessInfo.processInfo.systemUptime
        lastWavURL = recording.url
        lastAudioDurationMilliseconds = recording.durationMilliseconds
        updateRecoveryItems()
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
            lastAudioDurationMilliseconds = recording.durationMilliseconds
            updateRecoveryItems()
            Task { [weak self] in
                await self?.recordFailedTranscription(
                    wavURL: recording.url,
                    durationMilliseconds: recording.durationMilliseconds,
                    message: "Recording reached the one-hour safety limit before transcription."
                )
            }
        }
        print("Recording hit the 1-hour cap — stopped and saved (not auto-transcribed).")
    }
    private func showFailure(_ status: String = "Last transcription failed") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            self.setMenuStatus(status)
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            if let img = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "transcription failed"
            )?.withSymbolConfiguration(cfg) {
                img.isTemplate = false
                button.image = img
            }
        }
    }

    @objc private func reTranscribeLast() {
        guard modelReady,
              let url = lastWavURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        setMenuStatus("Transcribing…")
        transcribeAndPaste(
            wavURL: url,
            retrying: lastFailedHistoryID,
            audioDurationMilliseconds: lastAudioDurationMilliseconds
        )
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
                await self?.recordFailedTranscription(
                    wavURL: recording.url,
                    durationMilliseconds: recording.durationMilliseconds,
                    message: error.localizedDescription
                )
                DispatchQueue.main.async { [weak self] in
                    self?.practiceWindow?.transcriptionDidFail()
                }
            }
        }
    }

    private func transcribeAndPaste(
        wavURL: URL,
        retrying failureID: Int64? = nil,
        audioDurationMilliseconds: Int? = nil
    ) {
        setMenuStatus("Transcribing…")
        let started = ProcessInfo.processInfo.systemUptime
        let transcriber = transcriber
        Task { [weak self] in
            do {
                let raw = try await transcriber.transcribe(wavURL)
                let inferenceFinished = ProcessInfo.processInfo.systemUptime
                await self?.finishTranscription(
                    raw: raw,
                    wavURL: wavURL,
                    audioDurationMS: audioDurationMilliseconds ?? 0,
                    stopRequested: started,
                    audioFinalizeMS: 0,
                    inferenceMS: self?.milliseconds(from: started, to: inferenceFinished) ?? 0,
                    replacingFailureID: failureID
                )
            } catch {
                print("Fluid Unified transcription failed: \(error)")
                if failureID == nil {
                    await self?.recordFailedTranscription(
                        wavURL: wavURL,
                        durationMilliseconds: audioDurationMilliseconds,
                        message: error.localizedDescription
                    )
                } else {
                    self?.showFailure()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.practiceWindow?.transcriptionDidFail()
                }
            }
        }
    }

    private func finishTranscription(
        raw: String,
        wavURL: URL,
        audioDurationMS: Int,
        stopRequested: TimeInterval,
        audioFinalizeMS: Int,
        inferenceMS: Int,
        replacingFailureID: Int64? = nil
    ) async {
        let cleanupStarted = ProcessInfo.processInfo.systemUptime
        let text = Postprocessor.process(raw)
        do {
            let rowID: Int64
            if let replacingFailureID {
                try await HistoryStore.shared.resolveFailure(
                    id: replacingFailureID,
                    text: text,
                    durationMilliseconds: audioDurationMS == 0 ? nil : audioDurationMS,
                    source: "fluid-unified"
                )
                rowID = replacingFailureID
            } else {
                rowID = try await HistoryStore.shared.save(
                    audioPath: wavURL.path,
                    text: text,
                    durationMilliseconds: audioDurationMS == 0 ? nil : audioDurationMS,
                    source: "fluid-unified"
                )
            }
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
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.lastFailedHistoryID == replacingFailureID {
                        self.lastFailedHistoryID = nil
                    }
                    self.updateRecoveryItems()
                    self.historyWindow?.loadHistory()
                    self.refreshReadyStatus()
                    self.practiceWindow?.transcriptionDidFail()
                }
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
                    self.pasteLastItem?.isEnabled = true
                    if self.lastFailedHistoryID == replacingFailureID {
                        self.lastFailedHistoryID = nil
                    }
                    self.updateRecoveryItems()
                    if let practice = self.practiceWindow {
                        practice.transcriptionDidFinish(text: text)
                        continuation.resume()
                    } else {
                        self.pasteText(text) {
                            continuation.resume()
                        }
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
            DispatchQueue.main.async { [weak self] in
                self?.historyWindow?.loadHistory()
                self?.refreshReadyStatus()
            }
        } catch {
            print("Could not save transcription history: \(error.localizedDescription)")
            showFailure("Could not save transcription")
        }
    }

    private func recordFailedTranscription(
        wavURL: URL,
        durationMilliseconds: Int?,
        message: String
    ) async {
        do {
            let rowID = try await HistoryStore.shared.saveFailure(
                audioPath: wavURL.path,
                durationMilliseconds: durationMilliseconds,
                source: "fluid-unified",
                errorMessage: message
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastFailedHistoryID = rowID
                self.historyWindow?.loadHistory()
                self.updateRecoveryItems()
                self.showFailure()
            }
        } catch {
            print("Could not save failed transcription: \(error.localizedDescription)")
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

    // The last few characters before the insertion point in the focused text field.
    // Some terminal and Electron controls expose a focused AX element but not its
    // selected range; retaining the process ID still lets consecutive dictations in
    // that untouched target join without relying on a trailing space.
    private func focusedPasteContext() -> FocusedPasteContext {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
        CFGetTypeID(focused!) == AXUIElementGetTypeID() else {
            return FocusedPasteContext(
                processIdentifier: frontmostPID,
                textBeforeCursor: nil
            )
        }
        let element = focused as! AXUIElement
        var elementPID: pid_t = 0
        let processIdentifier = AXUIElementGetPid(element, &elementPID) == .success
            ? elementPID
            : frontmostPID

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success else {
            return FocusedPasteContext(
                processIdentifier: processIdentifier,
                textBeforeCursor: nil
            )
        }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection) else {
            return FocusedPasteContext(
                processIdentifier: processIdentifier,
                textBeforeCursor: nil
            )
        }
        let cursor = selection.location
        if cursor <= 0 {
            return FocusedPasteContext(
                processIdentifier: processIdentifier,
                textBeforeCursor: ""
            )
        }

        let start = max(0, cursor - 16)
        var wanted = CFRange(location: start, length: cursor - start)
        guard let wantedValue = AXValueCreate(.cfRange, &wanted) else {
            return FocusedPasteContext(
                processIdentifier: processIdentifier,
                textBeforeCursor: nil
            )
        }
        var stringRef: CFTypeRef?
        let textBeforeCursor: String?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            wantedValue,
            &stringRef
        ) == .success {
            textBeforeCursor = stringRef as? String
        } else {
            textBeforeCursor = nil
        }
        return FocusedPasteContext(
            processIdentifier: processIdentifier,
            textBeforeCursor: textBeforeCursor
        )
    }

    private func resetPasteJoinState(reason: String) {
        if lastPasteProcessIdentifier != nil || lastPastedDictation != nil {
            print("Paste join state reset: \(reason)")
        }
        lastPasteProcessIdentifier = nil
        lastPastedDictation = nil
    }

    private func validatePasteTargetAfterMouseEvent() {
        let previousProcessIdentifier = lastPasteProcessIdentifier
        guard previousProcessIdentifier != nil else { return }
        // The event tap runs before the clicked application updates focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let currentProcessIdentifier = self.focusedPasteContext().processIdentifier
            if PasteJoinEventFilter.mouseChangedProcess(
                previous: previousProcessIdentifier,
                current: currentProcessIdentifier
            ) {
                self.resetPasteJoinState(reason: "mouse-process-changed")
            }
        }
    }

    private func pasteText(_ text: String, onIssued: (() -> Void)? = nil) {
        pasteboardRestore?.cancel()
        pasteboardRestore = nil
        pendingPastes.append(PendingPaste(text: text, onIssued: onIssued))
        issueNextPasteIfNeeded()
    }

    private func issueNextPasteIfNeeded() {
        guard !pasteIsInFlight, !pendingPastes.isEmpty else { return }
        pasteIsInFlight = true
        let pending = pendingPastes.removeFirst()
        let focus = focusedPasteContext()
        let sameUnchangedTarget = focus.processIdentifier != nil
            && focus.processIdentifier == lastPasteProcessIdentifier
        let insertion = DictationJoiner.joining(
            pending.text,
            contextBeforeCursor: focus.textBeforeCursor,
            priorDictation: sameUnchangedTarget ? lastPastedDictation : nil
        )
        let toPaste = insertion.pasteText
        let contextKind: String
        if focus.textBeforeCursor == nil {
            contextKind = "unavailable"
        } else if focus.textBeforeCursor?.isEmpty == true {
            contextKind = "empty"
        } else {
            contextKind = "text"
        }
        let separatorKind = insertion.typePeriodBeforePaste
            ? "typed-sentence"
            : (toPaste == pending.text
                ? "none"
                : (toPaste.hasPrefix(". ") ? "sentence" : "space"))
        print(
            "Paste join: ax=\(contextKind) sameProcess=\(sameUnchangedTarget) " +
            "prior=\(sameUnchangedTarget && lastPastedDictation != nil) separator=\(separatorKind)"
        )

        let pasteboard = NSPasteboard.general
        if !pasteboardSnapshotTaken {
            pasteboardStringBeforeSequence = pasteboard.string(forType: .string)
            pasteboardSnapshotTaken = true
        }
        pasteboard.clearContents()
        pasteboard.setString(toPaste, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else {
                pending.onIssued?()
                return
            }
            let source = CGEventSource(stateID: .hidSystemState)
            if insertion.typePeriodBeforePaste {
                let periodDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_ANSI_Period),
                    keyDown: true
                )
                periodDown?.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.syntheticPasteMarker
                )
                periodDown?.post(tap: .cgSessionEventTap)
                let periodUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_ANSI_Period),
                    keyDown: false
                )
                periodUp?.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.syntheticPasteMarker
                )
                periodUp?.post(tap: .cgSessionEventTap)
            }

            let issuePaste = {
                // Some terminal event paths discard eventSourceUserData. Keep a
                // short command-V-specific fallback window so our delayed paste
                // cannot erase the join state after it is recorded below.
                self.syntheticPasteFallbackDeadline =
                    ProcessInfo.processInfo.systemUptime + 0.5
                let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_ANSI_V),
                    keyDown: true
                )
                keyDown?.flags = .maskCommand
                keyDown?.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.syntheticPasteMarker
                )
                keyDown?.post(tap: .cgSessionEventTap)
                let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_ANSI_V),
                    keyDown: false
                )
                keyUp?.flags = .maskCommand
                keyUp?.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.syntheticPasteMarker
                )
                keyUp?.post(tap: .cgSessionEventTap)

                self.lastPasteProcessIdentifier = focus.processIdentifier
                self.lastPastedDictation = pending.text
                pending.onIssued?()

                // Let the target consume Cmd-V before another dictation replaces
                // the shared pasteboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self else { return }
                    self.pasteIsInFlight = false
                    if self.pendingPastes.isEmpty {
                        self.schedulePasteboardRestore(expectedCurrentString: toPaste)
                    } else {
                        self.issueNextPasteIfNeeded()
                    }
                }
            }

            if insertion.typePeriodBeforePaste {
                // Keep the typed period ahead of CMUX's bracketed-paste handling.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: issuePaste)
            } else {
                issuePaste()
            }
        }
    }

    private func schedulePasteboardRestore(expectedCurrentString: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            if pasteboard.string(forType: .string) == expectedCurrentString {
                pasteboard.clearContents()
                if let previous = self.pasteboardStringBeforeSequence {
                    pasteboard.setString(previous, forType: .string)
                }
            }
            self.pasteboardStringBeforeSequence = nil
            self.pasteboardSnapshotTaken = false
            self.pasteboardRestore = nil
        }
        pasteboardRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(onRetry: { [weak self] entry in
                guard let self else { return }
                let url = URL(fileURLWithPath: entry.audioPath)
                self.lastWavURL = url
                self.lastAudioDurationMilliseconds = entry.durationMilliseconds
                self.lastFailedHistoryID = entry.id
                self.updateRecoveryItems()
                self.transcribeAndPaste(
                    wavURL: url,
                    retrying: entry.id,
                    audioDurationMilliseconds: entry.durationMilliseconds
                )
            })
        }
        historyWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showDictionary() {
        if dictionaryWindow == nil {
            dictionaryWindow = DictionaryWindowController()
        }
        dictionaryWindow?.show()
    }

    @objc private func showCleanup() {
        if cleanupWindow == nil {
            cleanupWindow = CleanupWindowController()
        }
        cleanupWindow?.show()
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowController()
        }
        aboutWindow?.show()
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
            showFailure("Could not change Open at Login")
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

