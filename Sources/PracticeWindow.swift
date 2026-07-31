import Cocoa

final class PracticeWindowController: NSObject, NSWindowDelegate {
    private let onRevealMenu: () -> Void
    private let onCancel: () -> Void
    private var window: NSWindow!
    private var iconContainer: NSView!
    private var stateIcon: NSImageView!
    private var stateTitle: NSTextField!
    private var stateDetail: NSTextField!
    private var textView: NSTextView!
    private var placeholder: NSTextField!
    private var revealButton: NSButton!
    private var finished = false

    init(onRevealMenu: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onRevealMenu = onRevealMenu
        self.onCancel = onCancel
        super.init()
        buildWindow()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func recordingDidStart() {
        guard !finished else { return }
        placeholder.isHidden = true
        revealButton.isHidden = true
        updateState(
            symbol: "mic.fill",
            color: .systemRed,
            title: "Listening…",
            detail: "Say anything. Press Globe again when you’re done."
        )
    }

    func transcriptionDidStart() {
        guard !finished else { return }
        updateState(
            symbol: "waveform",
            color: WhisperOwnBrand.teal,
            title: "Turning speech into text…",
            detail: "The model is running locally on this Mac."
        )
    }

    func transcriptionDidFinish(text: String) {
        guard !finished else { return }
        textView.string = text
        placeholder.isHidden = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateState(
            symbol: "checkmark",
            color: WhisperOwnBrand.teal,
            title: "That was the real thing.",
            detail: "Recorded, transcribed, and cleaned up locally on this Mac."
        )
        revealButton.isHidden = false
        revealButton.isEnabled = true
        revealButton.keyEquivalent = "\r"
    }

    func transcriptionDidFail() {
        guard !finished else { return }
        updateState(
            symbol: "exclamationmark",
            color: WhisperOwnBrand.amber,
            title: "That one didn’t land.",
            detail: "Your recording is safe in History. Press Globe to try again."
        )
        placeholder.stringValue = "Your next transcript will appear here."
        placeholder.isHidden = false
        window.makeFirstResponder(textView)
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperOwn — Try It"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = WhisperOwnBrand.ink
        window.delegate = self
        self.window = window

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = WhisperOwnBrand.ink.cgColor

        let eyebrow = NSTextField(labelWithString: "TRY IT FOR REAL")
        eyebrow.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        eyebrow.textColor = WhisperOwnBrand.teal
        eyebrow.attributedStringValue = NSAttributedString(
            string: eyebrow.stringValue,
            attributes: [
                .font: eyebrow.font as Any,
                .foregroundColor: WhisperOwnBrand.teal,
                .kern: 1.1,
            ]
        )

        let title = NSTextField(labelWithString: "Say one sentence.")
        title.font = WhisperOwnBrand.displayFont(size: 27)
        title.textColor = WhisperOwnBrand.paper

        let intro = NSTextField(labelWithString: "Press Globe. Say anything. Press Globe again.")
        intro.font = NSFont.systemFont(ofSize: 13)
        intro.textColor = WhisperOwnBrand.secondaryText

        iconContainer = NSView()
        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 28
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconContainer.heightAnchor.constraint(equalToConstant: 56).isActive = true

        stateIcon = NSImageView()
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(stateIcon)
        NSLayoutConstraint.activate([
            stateIcon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            stateIcon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])

        stateTitle = NSTextField(labelWithString: "Press Globe to start")
        stateTitle.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        stateTitle.textColor = WhisperOwnBrand.paper
        stateDetail = NSTextField(wrappingLabelWithString: "The menu-bar microphone turns red while WhisperOwn listens.")
        stateDetail.font = NSFont.systemFont(ofSize: 11.5)
        stateDetail.textColor = WhisperOwnBrand.secondaryText
        let stateCopy = NSStackView(views: [stateTitle, stateDetail])
        stateCopy.orientation = .vertical
        stateCopy.alignment = .leading
        stateCopy.spacing = 3

        let stateRow = NSStackView(views: [iconContainer, stateCopy])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 14

        let editorCard = NSView()
        editorCard.wantsLayer = true
        editorCard.layer?.backgroundColor = WhisperOwnBrand.surface.cgColor
        editorCard.layer?.cornerRadius = 12
        editorCard.layer?.borderWidth = 1
        editorCard.layer?.borderColor = WhisperOwnBrand.surfaceRaised.cgColor

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        textView = NSTextView()
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 18)
        textView.textColor = WhisperOwnBrand.paper
        textView.insertionPointColor = WhisperOwnBrand.teal
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isRichText = false
        scroll.documentView = textView

        placeholder = NSTextField(labelWithString: "Your transcript will appear here.")
        placeholder.font = NSFont.systemFont(ofSize: 18)
        placeholder.textColor = WhisperOwnBrand.secondaryText.withAlphaComponent(0.62)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editorCard.addSubview(scroll)
        editorCard.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: editorCard.topAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: -2),
            placeholder.topAnchor.constraint(equalTo: editorCard.topAnchor, constant: 15),
            placeholder.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 17),
        ])


        let skip = NSButton(title: "Skip", target: self, action: #selector(skipTapped))
        skip.bezelStyle = .inline
        revealButton = NSButton(title: "Show me the menu", target: self, action: #selector(revealTapped))
        revealButton.bezelStyle = .rounded
        revealButton.isEnabled = false
        revealButton.isHidden = true
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [skip, footerSpacer, revealButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        for view in [eyebrow, title, intro, stateRow, editorCard, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            eyebrow.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            eyebrow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            intro.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            intro.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            stateRow.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 20),
            stateRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            stateRow.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            editorCard.topAnchor.constraint(equalTo: stateRow.bottomAnchor, constant: 17),
            editorCard.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            editorCard.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            editorCard.heightAnchor.constraint(equalToConstant: 126),


            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        window.contentView = root
        updateState(
            symbol: "globe",
            color: WhisperOwnBrand.teal,
            title: "Press Globe to start",
            detail: "The menu-bar microphone turns red while WhisperOwn listens."
        )
    }

    private func updateState(symbol: String, color: NSColor, title: String, detail: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        stateIcon.image = image
        iconContainer.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        stateTitle.stringValue = title
        stateDetail.stringValue = detail
    }


    @objc private func revealTapped() {
        guard !finished else { return }
        finished = true
        onRevealMenu()
        window.orderOut(nil)
    }

    @objc private func skipTapped() {
        finishAsCancelled()
    }

    func windowWillClose(_ notification: Notification) {
        finishAsCancelled()
    }

    private func finishAsCancelled() {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        onCancel()
    }
}


private final class MenuRevealArrowView: NSView {
    var arrowX: CGFloat = 170 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tipY = bounds.maxY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: arrowX, y: tipY))
        path.line(to: NSPoint(x: arrowX - 10, y: tipY - 11))
        path.line(to: NSPoint(x: arrowX + 10, y: tipY - 11))
        path.close()
        WhisperOwnBrand.ink.setFill()
        path.fill()
        WhisperOwnBrand.teal.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class MenuRevealWindowController: NSWindowController {
    private let contentController: MenuRevealViewController
    private let onDismiss: () -> Void
    private var outsideClickMonitor: Any?
    private var dismissWorkItem: DispatchWorkItem?
    private var didDismiss = false

    init(onDone: @escaping () -> Void) {
        let contentController = MenuRevealViewController(onDone: onDone)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentController.preferredContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = contentController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        self.contentController = contentController
        self.onDismiss = onDone
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { nil }

    override func close() {
        didDismiss = true
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        super.close()
    }

    func show(below anchor: NSView) {
        guard let window,
              let hostWindow = anchor.window,
              let screen = hostWindow.screen
        else { return }

        window.setContentSize(contentController.preferredContentSize)
        let size = window.frame.size
        let visible = screen.visibleFrame
        let anchorFrame = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        var origin = NSPoint(
            x: anchorFrame.midX - size.width / 2,
            y: anchorFrame.minY - size.height - 1
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)

        contentController.setArrowX(
            min(max(anchorFrame.midX - origin.x, 18), size.width - 18)
        )
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        self.dismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: dismissWorkItem)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.didDismiss else { return }
            self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.dismiss() }
            }
        }
    }

    private func dismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismiss()
    }
}

final class MenuRevealViewController: NSViewController {
    private let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 340, height: 304)
    }

    required init?(coder: NSCoder) { nil }

    func setArrowX(_ x: CGFloat) {
        (view as? MenuRevealArrowView)?.arrowX = x
    }

    override func loadView() {
        let root = MenuRevealArrowView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = WhisperOwnBrand.ink.cgColor
        body.layer?.cornerRadius = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        let eyebrow = NSTextField(labelWithString: "WHISPEROWN LIVES HERE")
        eyebrow.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        eyebrow.textColor = WhisperOwnBrand.teal
        eyebrow.alignment = .center

        let title = NSTextField(wrappingLabelWithString: "Everything else is one click away.")
        title.font = WhisperOwnBrand.displayFont(size: 21)
        title.textColor = WhisperOwnBrand.paper
        title.alignment = .center

        let rows = NSStackView(views: [
            menuRow("clock.arrow.circlepath", "History", "Every transcript and recording"),
            menuRow("doc.on.clipboard", "Paste Last Transcript", "Use it if the first paste lands elsewhere"),
            menuRow("slider.horizontal.3", "Settings", "Dictionary and cleanup rules"),
        ])
        rows.orientation = .vertical
        rows.spacing = 8

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        for item in [eyebrow, title, rows, done] {
            item.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(item)
        }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            eyebrow.topAnchor.constraint(equalTo: body.topAnchor, constant: 20),
            eyebrow.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            title.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 4),
            title.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            title.widthAnchor.constraint(equalToConstant: 300),
            rows.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            rows.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            rows.widthAnchor.constraint(equalToConstant: 300),
            done.topAnchor.constraint(greaterThanOrEqualTo: rows.bottomAnchor, constant: 14),
            done.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            done.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),
        ])
    }

    private func menuRow(_ symbol: String, _ title: String, _ detail: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.contentTintColor = WhisperOwnBrand.teal
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        heading.textColor = WhisperOwnBrand.paper
        let explanation = NSTextField(labelWithString: detail)
        explanation.font = NSFont.systemFont(ofSize: 10.5)
        explanation.textColor = WhisperOwnBrand.secondaryText

        let copy = NSStackView(views: [heading, explanation])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let content = NSStackView(views: [icon, copy])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 9
        content.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = WhisperOwnBrand.surface.cgColor
        row.layer?.cornerRadius = 8
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            content.centerXAnchor.constraint(equalTo: row.centerXAnchor),
        ])
        return row
    }

    @objc private func doneTapped() {
        onDone()
    }
}
