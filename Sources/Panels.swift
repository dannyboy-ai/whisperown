import Cocoa
import AVFoundation

// MARK: - History Window

final class HistoryWindowController: NSWindowController {
    private let onRetry: (HistoryEntry) -> Void
    private var stackView: NSStackView!
    private var countLabel: NSTextField!
    private var entries: [HistoryEntry] = []
    private var player: AVAudioPlayer?
    private weak var playingButton: NSButton?

    private let background = WhisperOwnBrand.ink
    private let cardColor = NSColor(red: 0.065, green: 0.12, blue: 0.15, alpha: 1)
    private let failedCardColor = NSColor(red: 0.14, green: 0.095, blue: 0.075, alpha: 1)
    private let textPrimary = WhisperOwnBrand.paper
    private let textSecondary = NSColor(red: 0.62, green: 0.68, blue: 0.69, alpha: 1)

    init(onRetry: @escaping (HistoryEntry) -> Void) {
        self.onRetry = onRetry
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 540, height: 420)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = background

        super.init(window: window)
        setupUI()
        loadHistory()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        loadHistory()
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = background.cgColor

        let title = NSTextField(labelWithString: "Your dictations")
        title.font = WhisperOwnBrand.displayFont(size: 27)
        title.textColor = textPrimary

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = textSecondary

        let privacy = NSTextField(labelWithString: "Audio and transcripts stay on this Mac.")
        privacy.font = NSFont.systemFont(ofSize: 11)
        privacy.textColor = WhisperOwnBrand.teal
        privacy.alignment = .right

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10

        let scroll = NSScrollView()
        scroll.documentView = stackView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 18, right: 0)

        for child in [title, countLabel!, privacy, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        stackView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            countLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            countLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            privacy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            privacy.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            privacy.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -24),
        ])
    }

    func loadHistory() {
        Task { [weak self] in
            do {
                let history = try await HistoryStore.shared.history(limit: 100)
                DispatchQueue.main.async {
                    self?.entries = history
                    self?.rebuildList()
                }
            } catch {
                print("Failed to load history: \(error.localizedDescription)")
            }
        }
    }

    private func rebuildList() {
        for child in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        let failures = entries.filter { $0.status == .failed }.count
        let dictationWord = entries.count == 1 ? "dictation" : "dictations"
        countLabel.stringValue = "\(entries.count) recent \(dictationWord)" +
            (failures > 0 ? "  ·  \(failures) needs attention" : "")
        countLabel.textColor = failures > 0 ? WhisperOwnBrand.amber : textSecondary

        guard !entries.isEmpty else {
            let empty = emptyState()
            stackView.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            return
        }

        for (index, entry) in entries.enumerated() {
            let card = entry.status == .failed
                ? failedCard(for: entry, index: index)
                : completedCard(for: entry, index: index)
            stackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
    }

    private func emptyState() -> NSView {
        let container = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "No dictations")
        icon.contentTintColor = WhisperOwnBrand.teal
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)

        let title = NSTextField(labelWithString: "Your first dictation will appear here")
        title.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        title.textColor = textPrimary
        title.alignment = .center

        let detail = NSTextField(labelWithString: "Press Globe, speak, then press Globe again.")
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = textSecondary
        detail.alignment = .center

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 72),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -72),
        ])
        return container
    }

    private func completedCard(for entry: HistoryEntry, index: Int) -> NSView {
        let card = baseCard(color: cardColor)
        let metadata = metadataLabel(for: entry)
        let play = iconButton(
            symbol: "play.circle",
            label: "Play recording",
            action: #selector(playRow(_:)),
            index: index
        )
        let reveal = iconButton(
            symbol: "folder",
            label: "Reveal recording in Finder",
            action: #selector(revealRow(_:)),
            index: index
        )
        let copy = iconButton(
            symbol: "doc.on.doc",
            label: "Copy transcript",
            action: #selector(copyRow(_:)),
            index: index
        )

        let actions = NSStackView(views: [play, reveal, copy])
        actions.orientation = .horizontal
        actions.spacing = 3

        let transcript = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = NSTextField(wrappingLabelWithString:
            transcript.isEmpty ? "No speech detected in this recording." : transcript
        )
        text.font = NSFont.systemFont(ofSize: 13.5)
        text.textColor = transcript.isEmpty ? textSecondary : textPrimary
        text.isSelectable = !transcript.isEmpty
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byWordWrapping

        for child in [metadata, actions, text] {
            child.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(child)
        }
        NSLayoutConstraint.activate([
            metadata.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            metadata.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),

            actions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: metadata.centerYAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: metadata.trailingAnchor, constant: 12),

            text.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 11),
            text.leadingAnchor.constraint(equalTo: metadata.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -17),
        ])
        return card
    }

    private func failedCard(for entry: HistoryEntry, index: Int) -> NSView {
        let card = baseCard(color: failedCardColor)
        card.layer?.borderColor = WhisperOwnBrand.amber.withAlphaComponent(0.55).cgColor
        card.layer?.borderWidth = 1

        let warning = NSImageView()
        warning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Transcription failed"
        )
        warning.contentTintColor = WhisperOwnBrand.amber
        warning.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

        let heading = NSTextField(labelWithString: "TRANSCRIPTION FAILED")
        heading.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        heading.textColor = WhisperOwnBrand.amber
        heading.attributedStringValue = NSAttributedString(
            string: heading.stringValue,
            attributes: [
                .font: heading.font as Any,
                .foregroundColor: WhisperOwnBrand.amber,
                .kern: 0.8,
            ]
        )

        let metadata = metadataLabel(for: entry)
        let message = NSTextField(wrappingLabelWithString:
            "Your recording is safe. Retry transcription or reveal the audio file in Finder."
        )
        message.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        message.textColor = textPrimary

        let detail = NSTextField(wrappingLabelWithString:
            entry.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Speech recognition did not complete."
        )
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = textSecondary
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail

        let retry = NSButton(title: "Retry", target: self, action: #selector(retryRow(_:)))
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.tag = index
        retry.contentTintColor = WhisperOwnBrand.amber

        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealRow(_:)))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        reveal.tag = index

        let play = iconButton(
            symbol: "play.circle",
            label: "Play recording",
            action: #selector(playRow(_:)),
            index: index
        )
        let actions = NSStackView(views: [retry, reveal, play])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        for child in [warning, heading, metadata, message, detail, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(child)
        }
        NSLayoutConstraint.activate([
            warning.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            warning.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            warning.widthAnchor.constraint(equalToConstant: 18),
            warning.heightAnchor.constraint(equalToConstant: 18),

            heading.leadingAnchor.constraint(equalTo: warning.trailingAnchor, constant: 8),
            heading.centerYAnchor.constraint(equalTo: warning.centerYAnchor),

            metadata.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            metadata.centerYAnchor.constraint(equalTo: warning.centerYAnchor),
            metadata.leadingAnchor.constraint(greaterThanOrEqualTo: heading.trailingAnchor, constant: 12),

            message.topAnchor.constraint(equalTo: warning.bottomAnchor, constant: 13),
            message.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            message.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            detail.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 7),
            detail.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: message.trailingAnchor),

            actions.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 14),
            actions.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            actions.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func baseCard(color: NSColor) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = color.cgColor
        card.layer?.cornerRadius = 12
        return card
    }

    private func metadataLabel(for entry: HistoryEntry) -> NSTextField {
        var value = formatTime(entry.createdAt)
        if let duration = entry.durationMilliseconds, duration > 0 {
            value += "  ·  " + formatDuration(duration)
        }
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        label.textColor = textSecondary
        return label
    }

    private func iconButton(
        symbol: String,
        label: String,
        action: Selector,
        index: Int
    ) -> NSButton {
        let button = NSButton()
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        button.isBordered = false
        button.contentTintColor = textSecondary
        button.toolTip = label
        button.tag = index
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func copyRow(_ sender: NSButton) {
        guard let entry = entry(for: sender), entry.status == .completed, !entry.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)

        let original = sender.image
        sender.contentTintColor = .systemGreen
        sender.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Copied"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak sender] in
            sender?.image = original
            sender?.contentTintColor = self?.textSecondary
        }
    }

    @objc private func retryRow(_ sender: NSButton) {
        guard let entry = entry(for: sender),
              entry.status == .failed,
              FileManager.default.fileExists(atPath: entry.audioPath)
        else {
            NSSound.beep()
            return
        }
        onRetry(entry)
    }

    @objc private func revealRow(_ sender: NSButton) {
        guard let entry = entry(for: sender),
              FileManager.default.fileExists(atPath: entry.audioPath)
        else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.audioPath)])
    }

    @objc private func playRow(_ sender: NSButton) {
        if let player, player.isPlaying, playingButton === sender {
            player.stop()
            self.player = nil
            setPlayGlyph(sender, playing: false)
            playingButton = nil
            return
        }
        player?.stop()
        if let previous = playingButton, previous !== sender {
            setPlayGlyph(previous, playing: false)
        }

        guard let entry = entry(for: sender),
              FileManager.default.fileExists(atPath: entry.audioPath),
              let nextPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: entry.audioPath))
        else {
            NSSound.beep()
            return
        }
        player = nextPlayer
        playingButton = sender
        nextPlayer.play()
        setPlayGlyph(sender, playing: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + nextPlayer.duration + 0.1) { [weak self, weak sender] in
            guard let self, let sender, self.playingButton === sender else { return }
            self.setPlayGlyph(sender, playing: false)
            self.playingButton = nil
            self.player = nil
        }
    }

    private func entry(for button: NSButton) -> HistoryEntry? {
        guard button.tag >= 0, button.tag < entries.count else { return nil }
        return entries[button.tag]
    }

    private func setPlayGlyph(_ button: NSButton, playing: Bool) {
        button.image = NSImage(
            systemSymbolName: playing ? "stop.circle" : "play.circle",
            accessibilityDescription: playing ? "Stop" : "Play"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = max(1, Int((Double(milliseconds) / 1_000).rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }

    private func formatTime(_ databaseValue: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: databaseValue) else { return databaseValue }

        let display = DateFormatter()
        display.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            display.dateFormat = "h:mm a"
            return "Today, " + display.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            display.dateFormat = "h:mm a"
            return "Yesterday, " + display.string(from: date)
        }
        display.dateFormat = "MMM d, h:mm a"
        return display.string(from: date)
    }
}

// MARK: - Settings

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.preferredContentSize = NSSize(width: 640, height: 560)

        let dictionary = DictionarySettingsViewController()
        let dictionaryItem = NSTabViewItem(viewController: dictionary)
        dictionaryItem.label = "Dictionary"
        dictionaryItem.image = NSImage(
            systemSymbolName: "text.book.closed",
            accessibilityDescription: "Dictionary"
        )
        tabs.addTabViewItem(dictionaryItem)

        let cleanup = CleanupSettingsViewController()
        let cleanupItem = NSTabViewItem(viewController: cleanup)
        cleanupItem.label = "Cleanup"
        cleanupItem.image = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "Cleanup"
        )
        tabs.addTabViewItem(cleanupItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperOwn Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = WhisperOwnBrand.ink
        window.contentViewController = tabs

        self.init(window: window)
    }

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class DictionarySettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let heard: String
        let written: String
    }

    private var entries: [Entry] = []
    private var tableView: NSTableView!
    private var heardField: NSTextField!
    private var writtenField: NSTextField!
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var feedbackLabel: NSTextField!

    private var dictionaryURL: URL { Paths.dictionary }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = WhisperOwnBrand.ink.cgColor
        view = root

        let title = NSTextField(labelWithString: "Teach WhisperOwn your words")
        title.font = WhisperOwnBrand.displayFont(size: 22)
        title.textColor = WhisperOwnBrand.paper

        let explanation = NSTextField(wrappingLabelWithString:
            "Add names, technical terms, and phrases that speech recognition should write differently."
        )
        explanation.font = NSFont.systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false

        let heardColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heard"))
        heardColumn.title = "When it hears"
        heardColumn.width = 260
        heardColumn.minWidth = 150
        tableView.addTableColumn(heardColumn)

        let writtenColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("written"))
        writtenColumn.title = "Write"
        writtenColumn.width = 290
        writtenColumn.minWidth = 150
        tableView.addTableColumn(writtenColumn)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        heardField = NSTextField()
        heardField.placeholderString = "What WhisperOwn hears"
        heardField.font = NSFont.systemFont(ofSize: 13)

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        arrow.textColor = .secondaryLabelColor
        arrow.alignment = .center

        writtenField = NSTextField()
        writtenField.placeholderString = "What it should write"
        writtenField.font = NSFont.systemFont(ofSize: 13)

        addButton = NSButton(title: "Add Word", target: self, action: #selector(addEntry))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"

        removeButton = NSButton(title: "Remove Selected", target: self, action: #selector(removeEntry))
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false

        feedbackLabel = NSTextField(labelWithString: "")
        feedbackLabel.font = NSFont.systemFont(ofSize: 11)
        feedbackLabel.textColor = .secondaryLabelColor

        for child in [
            title, explanation, scroll, heardField!, arrow, writtenField!,
            addButton!, removeButton!, feedbackLabel!,
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),

            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: heardField.topAnchor, constant: -22),

            heardField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            heardField.widthAnchor.constraint(equalTo: writtenField.widthAnchor),
            heardField.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -14),

            arrow.leadingAnchor.constraint(equalTo: heardField.trailingAnchor, constant: 9),
            arrow.centerYAnchor.constraint(equalTo: heardField.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 20),

            writtenField.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 9),
            writtenField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            writtenField.centerYAnchor.constraint(equalTo: heardField.centerYAnchor),

            removeButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            feedbackLabel.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 12),
            feedbackLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            addButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadEntries()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < entries.count, let tableColumn else { return nil }
        let cell = NSTableCellView()
        let value = tableColumn.identifier.rawValue == "heard"
            ? entries[row].heard : entries[row].written
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func addEntry() {
        let heard = heardField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = writtenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else {
            showFeedback("Both fields are required.", color: .systemOrange)
            return
        }

        var dictionary = loadDictionary()
        dictionary[heard] = written
        guard persist(dictionary) else { return }
        heardField.stringValue = ""
        writtenField.stringValue = ""
        loadEntries()
        showFeedback("Saved.", color: .systemGreen)
        view.window?.makeFirstResponder(heardField)
    }

    @objc private func removeEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        var dictionary = loadDictionary()
        dictionary.removeValue(forKey: entries[row].heard)
        guard persist(dictionary) else { return }
        loadEntries()
        showFeedback("Removed.", color: .secondaryLabelColor)
    }

    private func loadEntries() {
        entries = loadDictionary()
            .filter { !$0.key.hasPrefix("_") }
            .map { Entry(heard: $0.key, written: $0.value) }
            .sorted { $0.heard.localizedCaseInsensitiveCompare($1.heard) == .orderedAscending }
        tableView.reloadData()
        tableView.deselectAll(nil)
        removeButton.isEnabled = false
    }

    private func loadDictionary() -> [String: String] {
        guard let data = try? Data(contentsOf: dictionaryURL),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dictionary
    }

    private func persist(_ dictionary: [String: String]) -> Bool {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dictionary,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: dictionaryURL, options: .atomic)
            return true
        } catch {
            showFeedback("Could not save: \(error.localizedDescription)", color: .systemRed)
            return false
        }
    }

    private func showFeedback(_ message: String, color: NSColor) {
        feedbackLabel.stringValue = message
        feedbackLabel.textColor = color
    }
}

private final class CleanupSettingsViewController: NSViewController {
    private var textView: NSTextView!
    private var copyButton: NSButton!

    private let prompt = "WhisperOwn's dictation cleanup runs deterministic regex in Sources/Postprocessor.swift. I want to change a cleanup rule: <describe the change>. Edit the rule, add Swift fixtures covering BOTH the fix AND a near-miss it must not touch, then run the focused cleanup tests."

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = WhisperOwnBrand.ink.cgColor
        view = root

        let title = NSTextField(labelWithString: "Deterministic cleanup")
        title.font = WhisperOwnBrand.displayFont(size: 22)
        title.textColor = WhisperOwnBrand.paper

        let explanation = NSTextField(wrappingLabelWithString:
            "These local rules remove dictation artifacts without rewriting your words with an LLM."
        )
        explanation.font = NSFont.systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        scroll.documentView = textView

        let footer = NSTextField(labelWithString: "Want to change a rule?")
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor

        copyButton = NSButton(
            title: "Copy prompt for your agent",
            target: self,
            action: #selector(copyPrompt)
        )
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small

        for child in [title, explanation, scroll, footer, copyButton!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),

            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadRules()
    }

    @objc private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyButton.title = "Copy prompt for your agent"
        }
    }

    private func loadRules() {
        let rules = Postprocessor.rules.map {
            ["section": $0.section, "name": $0.name, "desc": $0.description]
        }
        textView.textStorage?.setAttributedString(render(rules))
    }

    private func render(_ rules: [[String: String]]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let headFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let descriptionFont = NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        paragraph.lineSpacing = 1
        var lastSection = ""

        for rule in rules {
            let section = rule["section"] ?? ""
            if section != lastSection {
                output.append(NSAttributedString(
                    string: (lastSection.isEmpty ? "" : "\n") + section.uppercased() + "\n",
                    attributes: [
                        .font: headFont,
                        .foregroundColor: WhisperOwnBrand.amber,
                        .kern: 0.8,
                    ]
                ))
                lastSection = section
            }
            output.append(NSAttributedString(
                string: (rule["name"] ?? "") + "\n",
                attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor]
            ))
            output.append(NSAttributedString(
                string: (rule["desc"] ?? "") + "\n",
                attributes: [
                    .font: descriptionFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return output
    }
}


// MARK: - Local Performance

final class PerformancePanelController: @unchecked Sendable {
    private let panel: NSPanel
    private let metrics = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 250),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Performance"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating

        let content = NSView(frame: panel.contentView!.bounds)
        let title = NSTextField(labelWithString: "Stop speaking → paste")
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Measured locally on this Mac. No timing or transcript data leaves WhisperOwn.")
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        metrics.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        metrics.textColor = .labelColor

        for view in [title, note, metrics] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            metrics.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 22),
            metrics.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
        panel.contentView = content
    }

    func showPanel() {
        metrics.stringValue = "Loading…"
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            let summary = await TimingStore.shared.summary()
            let latest = summary.latest
            let value: String
            if summary.sampleCount == 0 {
                value = "No completed dictations yet."
            } else {
                value = """
                samples   \(summary.sampleCount)
                median    \(summary.medianMS) ms
                p95       \(summary.p95MS) ms

                latest    \(latest?.totalMS ?? 0) ms
                ├─ audio finalize   \(latest?.audioFinalizeMS ?? 0) ms
                ├─ inference        \(latest?.inferenceMS ?? 0) ms
                ├─ cleanup/history  \(latest?.cleanupAndHistoryMS ?? 0) ms
                └─ paste issue      \(latest?.pasteIssueMS ?? 0) ms
                """
            }
            DispatchQueue.main.async {
                self?.metrics.stringValue = value
            }
        }
    }
}
