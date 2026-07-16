import Cocoa
import AVFoundation

// MARK: - History Window

class HistoryWindowController: NSWindowController {
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var transcriptions: [[String: Any]] = []
    private var player: AVAudioPlayer?
    private weak var playingButton: NSButton?

    // Colors
    private let bgColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    private let cardColor = NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0)
    private let cardHoverColor = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
    private let textPrimary = NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1.0)
    private let textSecondary = NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1.0)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 300)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

        self.init(window: window)
        setupUI()
        loadHistory()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        loadHistory()
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = bgColor.cgColor

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0

        scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        container.addSubview(scrollView)
        window.contentView = container
    }

    func loadHistory() {
        let url = URL(string: "http://localhost:8000/history?limit=100")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                print("Failed to load history: \(error?.localizedDescription ?? "bad response")")
                return
            }
            DispatchQueue.main.async {
                self?.transcriptions = json
                self?.rebuildList()
            }
        }.resume()
    }

    private func rebuildList() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if transcriptions.isEmpty {
            let empty = NSTextField(labelWithString: "No transcriptions yet.")
            empty.font = NSFont.systemFont(ofSize: 15, weight: .light)
            empty.textColor = textSecondary
            empty.alignment = .center
            let wrapper = NSView()
            wrapper.addSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
                empty.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 60),
                empty.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -60),
            ])
            stackView.addArrangedSubview(wrapper)
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            wrapper.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return
        }

        for (index, item) in transcriptions.enumerated() {
            let card = makeCard(item: item, index: index)
            stackView.addArrangedSubview(card)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 16).isActive = true
            card.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16).isActive = true

            if index < transcriptions.count - 1 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
                stackView.addArrangedSubview(spacer)
                spacer.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                spacer.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            }
        }
    }

    private func makeCard(item: [String: Any], index: Int) -> NSView {
        let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeRaw = (item["created_at"] as? String) ?? ""
        let timeDisplay = formatTime(timeRaw)

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = cardColor.cgColor
        card.layer?.cornerRadius = 10

        // --- Top row: timestamp + copy button ---
        let timeLabel = NSTextField(labelWithString: timeDisplay)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = textSecondary

        let copyButton = NSButton(frame: .zero)
        if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            copyButton.image = img.withSymbolConfiguration(config)
        }
        copyButton.isBordered = false
        copyButton.contentTintColor = textSecondary
        copyButton.toolTip = "Copy to clipboard"
        copyButton.tag = index
        copyButton.target = self
        copyButton.action = #selector(copyRow(_:))

        let trackingArea = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: copyButton, userInfo: nil
        )
        copyButton.addTrackingArea(trackingArea)

        let playButton = NSButton(frame: .zero)
        if let img = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Play") {
            playButton.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        }
        playButton.isBordered = false
        playButton.contentTintColor = textSecondary
        playButton.toolTip = "Play recording"
        playButton.tag = index
        playButton.target = self
        playButton.action = #selector(playRow(_:))
        playButton.translatesAutoresizingMaskIntoConstraints = false

        // --- Text content ---
        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        textField.textColor = textPrimary
        textField.isSelectable = true
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.allowsDefaultTighteningForTruncation = false

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 0
        let attributedString = NSMutableAttributedString(string: text)
        attributedString.addAttributes([
            .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
            .foregroundColor: textPrimary,
            .paragraphStyle: paragraphStyle,
        ], range: NSRange(location: 0, length: attributedString.length))
        textField.attributedStringValue = attributedString

        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping

        // --- Layout ---
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(timeLabel)
        card.addSubview(playButton)
        card.addSubview(copyButton)
        card.addSubview(textField)

        var constraints = [
            timeLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            timeLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),

            copyButton.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 28),

            playButton.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            playButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            playButton.widthAnchor.constraint(equalToConstant: 28),
            playButton.heightAnchor.constraint(equalToConstant: 28),

            textField.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 10),
            textField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ]

        constraints.append(
            textField.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        )

        NSLayoutConstraint.activate(constraints)

        return card
    }

    @objc private func copyRow(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < transcriptions.count else { return }

        if let text = transcriptions[index]["text"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            print("Copied: \(text)")

            let original = sender.contentTintColor
            sender.contentTintColor = NSColor.systemGreen
            if let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied") {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                sender.image = img.withSymbolConfiguration(config)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                sender.contentTintColor = original
                if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
                    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    sender.image = img.withSymbolConfiguration(config)
                }
            }
        }
    }

    @objc private func playRow(_ sender: NSButton) {
        let index = sender.tag
        // Second click on the row that's playing → stop it.
        if let p = player, p.isPlaying, playingButton === sender {
            p.stop(); player = nil
            setPlayGlyph(sender, playing: false)
            return
        }
        player?.stop()
        if let prev = playingButton, prev !== sender { setPlayGlyph(prev, playing: false) }

        guard index >= 0, index < transcriptions.count,
              let path = transcriptions[index]["audio_path"] as? String,
              FileManager.default.fileExists(atPath: path),
              let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            NSSound.beep(); return
        }
        player = p; playingButton = sender
        p.play()
        setPlayGlyph(sender, playing: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.1) { [weak self, weak sender] in
            guard let self = self, let sender = sender, self.playingButton === sender else { return }
            self.setPlayGlyph(sender, playing: false)
            self.playingButton = nil
        }
    }

    private func setPlayGlyph(_ button: NSButton, playing: Bool) {
        let name = playing ? "stop.circle" : "play.circle"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: playing ? "Stop" : "Play") {
            button.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        }
    }

    private func formatTime(_ isoString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: isoString) else { return isoString }

        let display = DateFormatter()
        display.timeZone = .current

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            display.dateFormat = "h:mm a"
            return "Today, " + display.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            display.dateFormat = "h:mm a"
            return "Yesterday, " + display.string(from: date)
        } else {
            display.dateFormat = "MMM d, h:mm a"
            return display.string(from: date)
        }
    }
}

// MARK: - Dictionary Panel

class DictionaryPanelController {
    private var panel: NSPanel!
    private var fromField: NSTextField!
    private var toField: NSTextField!
    private var entriesView: NSTextView!

    private var dictionaryURL: URL { Paths.dictionary }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Dictionary"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating

        setupUI()
    }

    private func setupUI() {
        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let entriesLabel = NSTextField(labelWithString: "Current entries:")
        entriesLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        entriesLabel.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        entriesView = NSTextView(frame: .zero)
        entriesView.isEditable = false
        entriesView.isSelectable = true
        entriesView.drawsBackground = false
        entriesView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        entriesView.textColor = .labelColor
        scroll.documentView = entriesView

        let fromLabel = NSTextField(labelWithString: "It hears:")
        fromLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fromLabel.textColor = .secondaryLabelColor

        fromField = NSTextField(frame: .zero)
        fromField.placeholderString = "e.g. whisper own"
        fromField.font = NSFont.systemFont(ofSize: 14)
        fromField.focusRingType = .none

        let toLabel = NSTextField(labelWithString: "Replace with:")
        toLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toLabel.textColor = .secondaryLabelColor

        toField = NSTextField(frame: .zero)
        toField.placeholderString = "e.g. WhisperOwn"
        toField.font = NSFont.systemFont(ofSize: 14)
        toField.focusRingType = .none

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        for view in [entriesLabel, scroll, fromLabel, fromField!, toLabel, toField!, saveButton, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            entriesLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            entriesLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: entriesLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 150),

            fromLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            fromLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            fromField.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 4),
            fromField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fromField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            toLabel.topAnchor.constraint(equalTo: fromField.bottomAnchor, constant: 12),
            toLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            toField.topAnchor.constraint(equalTo: toLabel.bottomAnchor, constant: 4),
            toField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            saveButton.topAnchor.constraint(equalTo: toField.bottomAnchor, constant: 16),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])

        panel.contentView = content
    }

    private func loadEntries() {
        var text = ""
        if let data = try? Data(contentsOf: dictionaryURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (k, v) in dict.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) where !k.hasPrefix("_") {
                text += "\(k)  →  \(v)\n"
            }
        }
        entriesView.string = text.isEmpty ? "(no entries yet)" : text
    }

    func showPanel() {
        loadEntries()
        fromField.stringValue = ""
        toField.stringValue = ""
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(fromField)
    }

    @objc private func cancel() {
        panel.close()
    }

    @objc private func save() {
        let from = fromField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = toField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return }

        var dictionary: [String: String] = [:]
        if let data = try? Data(contentsOf: dictionaryURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dictionary = existing
        }

        dictionary[from] = to

        if let jsonData = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: dictionaryURL)
            print("Dictionary updated: \"\(from)\" -> \"\(to)\"")
        }

        panel.close()
    }
}

// Read-only viewer of the active cleanup rules (fetched from the backend's /rules),
// grouped into sections. Editing is deliberately NOT here — the Copy-prompt button
// hands your agent a ready prompt; the agent edits server/postprocess.py.
class RulesPanelController {
    private var panel: NSPanel!
    private var textView: NSTextView!
    private var copyButton: NSButton!

    private let prompt = "WhisperOwn's dictation cleanup runs deterministic regex in server/postprocess.py, each rule documented in POSTPROCESS.md. I want to change a cleanup rule: <describe the change>. Edit the rule, add a fixture to server/test_postprocess.py covering BOTH the fix AND a near-miss it must not touch, then run `cd server && ./.venv/bin/python test_postprocess.py` and confirm all pass."

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered, defer: false)
        panel.title = "Cleanup Rules"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating

        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = textView

        let footer = NSTextField(labelWithString: "Add or change a rule →")
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor

        copyButton = NSButton(title: "Copy prompt for your agent", target: self, action: #selector(copyPrompt))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small

        for v in [scroll, footer, copyButton!] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
    }

    func showPanel() {
        loadRules()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copyButton.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyButton.title = "Copy prompt for your agent"
        }
    }

    private func loadRules() {
        textView.string = "Loading…"
        guard let url = URL(string: "http://localhost:8000/rules") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    self.textView.textStorage?.setAttributedString(self.render(arr))
                } else {
                    self.textView.string = "(couldn't reach the backend — is it running?)"
                }
            }
        }.resume()
    }

    private func render(_ rules: [[String: String]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let descFont = NSFont.systemFont(ofSize: 12)
        let descPara = NSMutableParagraphStyle(); descPara.paragraphSpacing = 9; descPara.lineSpacing = 1
        var lastSection = ""
        for r in rules {
            let section = r["section"] ?? ""
            if section != lastSection {
                out.append(NSAttributedString(string: (lastSection.isEmpty ? "" : "\n") + section.uppercased() + "\n",
                    attributes: [.font: headFont, .foregroundColor: NSColor.systemOrange, .kern: 0.8]))
                lastSection = section
            }
            out.append(NSAttributedString(string: (r["name"] ?? "") + "\n",
                attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor]))
            out.append(NSAttributedString(string: (r["desc"] ?? "") + "\n",
                attributes: [.font: descFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: descPara]))
        }
        return out
    }
}

