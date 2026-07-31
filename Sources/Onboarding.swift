import Cocoa
import AVFoundation

// A guided first-run window. Shown only when microphone or accessibility is
// missing. Each OS prompt fires one at a time, only when the user clicks its
// step — never both system dialogs at launch with no context. Statuses flip to a
// green check live (a poll), so granting is visible "click → ✓".

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let onDone: (Bool) -> Void
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

    private let rowWidth: CGFloat = 440

    init(onDone: @escaping (Bool) -> Void) {
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
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 492, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "WhisperOwn"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = WhisperOwnBrand.ink

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 22, right: 26)
        root.wantsLayer = true
        root.layer?.backgroundColor = WhisperOwnBrand.ink.cgColor

        let eyebrow = label(
            "PRIVATE, ON-DEVICE DICTATION",
            .systemFont(ofSize: 10.5, weight: .bold),
            WhisperOwnBrand.teal
        )
        eyebrow.attributedStringValue = NSAttributedString(
            string: eyebrow.stringValue,
            attributes: [
                .font: eyebrow.font as Any,
                .foregroundColor: WhisperOwnBrand.teal,
                .kern: 1.1,
            ]
        )
        root.addArrangedSubview(eyebrow)
        root.addArrangedSubview(label(
            "Three permissions. Then you’re done.",
            WhisperOwnBrand.displayFont(size: 25),
            WhisperOwnBrand.paper
        ))
        let intro = label(
            "WhisperOwn asks only for what makes Globe-to-paste work.",
            .systemFont(ofSize: 12.5),
            WhisperOwnBrand.secondaryText
        )
        root.addArrangedSubview(intro)
        root.setCustomSpacing(18, after: intro)

        micIcon = statusIcon("mic.fill")
        micButton = actionButton("Allow Microphone", #selector(micTapped))
        root.addArrangedSubview(stepRow(
            micIcon,
            "Microphone",
            "Records your voice for local transcription.",
            micButton
        ))

        axIcon = statusIcon("hand.raised.fill")
        axButton = actionButton("Open Accessibility…", #selector(axTapped))
        root.addArrangedSubview(stepRow(
            axIcon,
            "Accessibility",
            "Listens for Globe and pastes at your cursor.",
            axButton
        ))

        globeIcon = statusIcon("globe")
        globeButton = actionButton("Open Keyboard…", #selector(globeTapped))
        root.addArrangedSubview(stepRow(
            globeIcon,
            "Free the Globe key",
            "Set “Press 🌐 key to” to “Do Nothing.”",
            globeButton
        ))

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
        root.setCustomSpacing(16, after: root.arrangedSubviews.last!)
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


    private func statusIcon(_ symbol: String) -> NSImageView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.wantsLayer = true
        icon.layer?.backgroundColor = WhisperOwnBrand.teal.withAlphaComponent(0.12).cgColor
        icon.layer?.cornerRadius = 18
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [WhisperOwnBrand.teal]))
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)
        return icon
    }

    private func actionButton(_ t: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: action)
        b.bezelStyle = .rounded
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.widthAnchor.constraint(equalToConstant: 138).isActive = true
        return b
    }

    private func stepRow(_ icon: NSImageView, _ title: String, _ desc: String, _ button: NSButton) -> NSView {
        let name = label(title, .systemFont(ofSize: 14, weight: .semibold), WhisperOwnBrand.paper)
        let detail = label(desc, .systemFont(ofSize: 11.5), WhisperOwnBrand.secondaryText)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let contents = NSStackView(views: [icon, text, spacer, button])
        contents.orientation = .horizontal
        contents.alignment = .centerY
        contents.spacing = 12
        contents.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = WhisperOwnBrand.surface.cgColor
        card.layer?.cornerRadius = 11
        card.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        card.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            contents.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            contents.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            contents.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        return card
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
        setIcon(micIcon, micOK, pending: "mic.fill")
        setIcon(axIcon, axOK, pending: "hand.raised.fill")
        setIcon(globeIcon, globeOK, pending: "globe")
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

    private func setIcon(_ icon: NSImageView, _ done: Bool, pending symbol: String) {
        let name = done ? "checkmark" : symbol
        let color = done ? WhisperOwnBrand.teal : WhisperOwnBrand.paper
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: done ? "Complete" : nil
        )?.withSymbolConfiguration(config)
        image?.isTemplate = false
        icon.image = image
        icon.layer?.backgroundColor = (
            done ? WhisperOwnBrand.teal : WhisperOwnBrand.surfaceRaised
        ).withAlphaComponent(done ? 0.22 : 1).cgColor
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
        finish(startPractice: true)
    }

    func windowWillClose(_ notification: Notification) {
        finish(startPractice: false)
    }

    private func finish(startPractice: Bool) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        window.orderOut(nil)
        onDone(startPractice)
    }
}

