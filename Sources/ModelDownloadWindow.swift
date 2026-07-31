import Cocoa

final class ModelDownloadWindowController: NSWindowController, NSWindowDelegate {
    private let onRetry: () -> Void
    private let onCancel: () -> Void
    private var eyebrowLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var explanationLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var actionButton: NSButton!
    private var isActive = false

    init(onRetry: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onRetry = onRetry
        self.onCancel = onCancel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 488),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperOwn Setup"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = WhisperOwnBrand.ink

        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ state: ModelPreparationState) {
        switch state {
        case .preparing:
            showSetupCopy()
            isActive = true
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            statusLabel.stringValue = "Checking local model files…"
            actionButton.title = "Cancel"
            actionButton.isEnabled = true
        case .progress(let fraction, let detail):
            showSetupCopy()
            isActive = true
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            progress.doubleValue = min(max(fraction, 0), 1) * 100
            statusLabel.stringValue = detail
            actionButton.title = "Cancel"
            actionButton.isEnabled = true
        case .ready:
            window?.title = "Speech Model"
            eyebrowLabel.stringValue = "ON-DEVICE SPEECH MODEL"
            titleLabel.stringValue = "Parakeet Unified is ready."
            explanationLabel.stringValue = "WhisperOwn uses the Parakeet Unified English 0.6B model, powered by FluidAudio. Its 594 MB of model files live in Application Support; audio and transcripts stay on this Mac."
            isActive = false
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            progress.doubleValue = 100
            progress.isHidden = true
            statusLabel.stringValue = "Ready for dictation"
            actionButton.title = "Done"
            actionButton.isEnabled = true
        case .failed(let message):
            showSetupCopy()
            isActive = false
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            statusLabel.stringValue = "Download failed: \(message)"
            actionButton.title = "Retry"
            actionButton.isEnabled = true
        case .cancelled:
            showSetupCopy()
            isActive = false
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            statusLabel.stringValue = "Download paused. Recording stays disabled until setup finishes."
            actionButton.title = "Resume"
            actionButton.isEnabled = true
        }
    }

    private func showSetupCopy() {
        window?.title = "WhisperOwn Setup"
        eyebrowLabel.stringValue = "PRIVATE SPEECH MODEL"
        titleLabel.stringValue = "Your voice stays on this Mac."
        explanationLabel.stringValue = "WhisperOwn downloads its 594 MB speech model once. After this, dictation runs locally — no account, cloud, or subscription."
        progress.isHidden = false
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let hero = WhisperOwnBrand.heroImageView()

        eyebrowLabel = NSTextField(labelWithString: "PRIVATE SPEECH MODEL")
        let eyebrow = eyebrowLabel!
        eyebrow.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        eyebrow.textColor = WhisperOwnBrand.teal
        eyebrow.attributedStringValue = NSAttributedString(
            string: eyebrow.stringValue,
            attributes: [
                .font: eyebrow.font as Any,
                .foregroundColor: WhisperOwnBrand.teal,
                .kern: 1.2,
            ]
        )

        titleLabel = NSTextField(labelWithString: "Your voice stays on this Mac.")
        let title = titleLabel!
        title.font = WhisperOwnBrand.displayFont(size: 25)
        title.textColor = .labelColor

        explanationLabel = NSTextField(wrappingLabelWithString: "WhisperOwn downloads its 594 MB speech model once. After this, dictation runs locally — no account, cloud, or subscription.")
        let explanation = explanationLabel!
        explanation.font = NSFont.systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100

        statusLabel = NSTextField(wrappingLabelWithString: "Checking local model files…")
        statusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        actionButton = NSButton(title: "Cancel", target: self, action: #selector(actionTapped))
        actionButton.bezelStyle = .rounded

        let views: [NSView] = [hero, eyebrow, title, explanation, progress, statusLabel, actionButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            hero.widthAnchor.constraint(equalToConstant: 472),
            hero.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            hero.heightAnchor.constraint(equalToConstant: 236),

            eyebrow.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            eyebrow.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 17),

            title.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            title.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: hero.trailingAnchor),

            explanation.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            explanation.trailingAnchor.constraint(equalTo: hero.trailingAnchor),

            progress.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            progress.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 18),

            statusLabel.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 9),
            statusLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -16),

            actionButton.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 88),
            actionButton.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 11),
        ])
    }

    @objc private func actionTapped() {
        if isActive {
            actionButton.isEnabled = false
            statusLabel.stringValue = "Pausing after the current file…"
            onCancel()
        } else if actionButton.title == "Done" {
            close()
        } else {
            onRetry()
        }
    }
}
