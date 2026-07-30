import Cocoa

final class ModelDownloadWindowController: NSWindowController, NSWindowDelegate {
    private let onRetry: () -> Void
    private let onCancel: () -> Void
    private var progress: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var actionButton: NSButton!
    private var isActive = false

    init(onRetry: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onRetry = onRetry
        self.onCancel = onCancel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperOwn Setup"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)

        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ state: ModelPreparationState) {
        switch state {
        case .preparing:
            isActive = true
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            statusLabel.stringValue = "Checking local model files…"
            actionButton.title = "Cancel"
            actionButton.isEnabled = true
        case .progress(let fraction, let detail):
            isActive = true
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            progress.doubleValue = min(max(fraction, 0), 1) * 100
            statusLabel.stringValue = detail
            actionButton.title = "Cancel"
            actionButton.isEnabled = true
        case .ready:
            isActive = false
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            progress.doubleValue = 100
            statusLabel.stringValue = "Ready. Speech recognition stays on this Mac."
            actionButton.title = "Done"
            actionButton.isEnabled = true
        case .failed(let message):
            isActive = false
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            statusLabel.stringValue = "Download failed: \(message)"
            actionButton.title = "Retry"
            actionButton.isEnabled = true
        case .cancelled:
            isActive = false
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            statusLabel.stringValue = "Download paused. Recording stays disabled until setup finishes."
            actionButton.title = "Resume"
            actionButton.isEnabled = true
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speech model")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        icon.contentTintColor = .systemOrange

        let title = NSTextField(labelWithString: "One local speech model")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor

        let explanation = NSTextField(wrappingLabelWithString: "WhisperOwn needs a 594 MB model before it can record. It downloads once, runs on Apple silicon, and keeps your audio on this Mac.")
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

        let views: [NSView] = [icon, title, explanation, progress, statusLabel, actionButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            progress.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 22),

            statusLabel.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
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
