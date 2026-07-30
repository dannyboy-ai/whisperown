import Cocoa

final class AboutWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 535),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About WhisperOwn"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = WhisperOwnBrand.ink

        self.init(window: window)
        buildContent()
    }

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = WhisperOwnBrand.ink.cgColor

        let hero = WhisperOwnBrand.heroImageView()

        let name = NSTextField(labelWithString: "WhisperOwn")
        name.font = WhisperOwnBrand.displayFont(size: 28)
        name.textColor = WhisperOwnBrand.paper
        name.alignment = .center

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        versionLabel.textColor = WhisperOwnBrand.teal
        versionLabel.alignment = .center

        let promise = NSTextField(wrappingLabelWithString:
            "On-device dictation. No cloud, accounts, subscriptions, or telemetry."
        )
        promise.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        promise.textColor = WhisperOwnBrand.paper
        promise.alignment = .center

        let credits = NSTextField(wrappingLabelWithString:
            "Speech recognition by FluidAudio and NVIDIA Parakeet Unified. Licensed under MIT."
        )
        credits.font = NSFont.systemFont(ofSize: 11)
        credits.textColor = .secondaryLabelColor
        credits.alignment = .center

        let githubButton = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .rounded

        let issueButton = NSButton(title: "Report an Issue", target: self, action: #selector(reportIssue))
        issueButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [githubButton, issueButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        for child in [hero, name, versionLabel, promise, credits, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }

        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            hero.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            hero.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            hero.heightAnchor.constraint(equalToConstant: 224),

            name.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 20),
            name.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            name.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),

            versionLabel.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            versionLabel.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            versionLabel.trailingAnchor.constraint(equalTo: name.trailingAnchor),

            promise.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 16),
            promise.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 54),
            promise.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -54),

            credits.topAnchor.constraint(equalTo: promise.bottomAnchor, constant: 12),
            credits.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 54),
            credits.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -54),

            buttons.topAnchor.constraint(equalTo: credits.bottomAnchor, constant: 20),
            buttons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
        ])
    }

    @objc private func openGitHub() {
        open("https://github.com/dannyboy-ai/whisperown")
    }

    @objc private func reportIssue() {
        open("https://github.com/dannyboy-ai/whisperown/issues/new")
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
