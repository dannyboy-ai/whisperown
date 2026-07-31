import Cocoa
import AVFoundation

// A guided first-run window. Shown only when microphone or accessibility is
// missing. Each OS prompt fires one at a time, only when the user clicks its
// step — never both system dialogs at launch with no context. Statuses flip to a
// green check live (a poll), so granting is visible "click → ✓".

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let onDone: () -> Void
    private var window: NSWindow!
    private var pollTimer: Timer?
    private var finished = false
    private var showingTutorial = false

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

        finishButton = NSButton(title: "Continue", target: self, action: #selector(finishTapped))
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

    private func showTutorial() {
        showingTutorial = true
        pollTimer?.invalidate()
        window.title = "WhisperOwn — Quick Start"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = WhisperOwnBrand.ink

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 13
        root.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 22, right: 26)

        let eyebrow = label("ONE KEY. TWO PRESSES.", .systemFont(ofSize: 10.5, weight: .bold), WhisperOwnBrand.teal)
        eyebrow.attributedStringValue = NSAttributedString(
            string: eyebrow.stringValue,
            attributes: [
                .font: eyebrow.font as Any,
                .foregroundColor: WhisperOwnBrand.teal,
                .kern: 1.2,
            ]
        )
        root.addArrangedSubview(eyebrow)
        root.addArrangedSubview(label("You’re ready to whisper.", WhisperOwnBrand.displayFont(size: 26), .labelColor))
        root.addArrangedSubview(label("WhisperOwn follows one simple rhythm.", .systemFont(ofSize: 13), .secondaryLabelColor))

        root.addArrangedSubview(tutorialRow(
            symbol: "mic.fill",
            title: "Press Globe to record",
            detail: "The upper-right microphone turns red while WhisperOwn is listening.",
            tint: .systemRed
        ))
        root.addArrangedSubview(tutorialRow(
            symbol: "waveform",
            title: "Speak naturally",
            detail: "Keep working or switch apps while WhisperOwn records.",
            tint: WhisperOwnBrand.teal
        ))
        root.addArrangedSubview(tutorialRow(
            symbol: "cursorarrow.rays",
            title: "Place your cursor",
            detail: "Click where the transcript should land before you finish.",
            tint: WhisperOwnBrand.teal
        ))
        root.addArrangedSubview(tutorialRow(
            symbol: "globe",
            title: "Press Globe again",
            detail: "Recording stops and your transcript pastes at the cursor.",
            tint: WhisperOwnBrand.amber
        ))

        let menuNote = label(
            "History, Paste Last Transcript, your dictionary, and troubleshooting live under the WhisperOwn microphone in the menu bar.",
            .systemFont(ofSize: 12),
            .secondaryLabelColor
        )
        menuNote.widthAnchor.constraint(equalToConstant: 468).isActive = true
        root.addArrangedSubview(menuNote)

        let startButton = NSButton(title: "Start using WhisperOwn", target: self, action: #selector(finishTapped))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, startButton])
        footer.orientation = .horizontal
        footer.widthAnchor.constraint(equalToConstant: 468).isActive = true
        root.addArrangedSubview(footer)

        window.contentView = root
        root.layoutSubtreeIfNeeded()
        window.setContentSize(root.fittingSize)
        window.center()
    }

    private func tutorialRow(symbol: String, title: String, detail: String, tint: NSColor) -> NSView {
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.wantsLayer = true
        iconContainer.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        iconContainer.layer?.cornerRadius = 19
        iconContainer.widthAnchor.constraint(equalToConstant: 38).isActive = true
        iconContainer.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        icon.contentTintColor = tint
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])

        let heading = label(title, .systemFont(ofSize: 14, weight: .semibold), .labelColor)
        let explanation = label(detail, .systemFont(ofSize: 12), .secondaryLabelColor)
        let copy = NSStackView(views: [heading, explanation])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 2

        let row = NSStackView(views: [iconContainer, copy])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 468).isActive = true
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

    @objc private func finishTapped() {
        if showingTutorial {
            finish()
        } else {
            showTutorial()
        }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        window.orderOut(nil)
        onDone()
    }
}

