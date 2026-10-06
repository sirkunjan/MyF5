import AppKit

/// A native menu bar and a guided first-run flow. Recording starts only after
/// the person presses the clearly labelled enrollment button.
final class MyF5Menu: NSObject, NSMenuDelegate, NSWindowDelegate {
    var status: () -> (enabled: Bool, busy: Bool, enrolled: Bool, description: String)
    var toggle: () -> Void
    var beginSetup: () -> Bool
    var endSetup: (Bool) -> Void
    var enroll: (@escaping (Double, Double, String?) -> Void, @escaping (String?) -> Void) -> Void
    var cancelEnrollment: () -> Void
    var recalibrate: () -> Void
    var permissions: () -> (mic: Bool, typing: Bool)
    var requestMic: () -> Void
    var requestTyping: () -> Void
    var saveSettings: ([String: Any]) -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var journalItem: NSMenuItem!
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var step = 0
    private var recording = false
    private var completionClosing = false
    private var stack: NSStackView?
    private var progressLabel: NSTextField?
    private var promptView: NSTextView?
    private var promptWordsRead = 0
    private var promptText = ""
    private var enrollmentSeconds = 0.0
    private var permissionLabel: NSTextField?
    private var nextButton: NSButton?
    private var recordButton: NSButton?
    private var enrollSucceeded = false
    private var permissionTimer: Timer?
    private var settingsControls: [String: NSControl] = [:]

    init(status: @escaping () -> (Bool, Bool, Bool, String), toggle: @escaping () -> Void,
         beginSetup: @escaping () -> Bool, endSetup: @escaping (Bool) -> Void,
         enroll: @escaping (@escaping (Double, Double, String?) -> Void, @escaping (String?) -> Void) -> Void,
         cancelEnrollment: @escaping () -> Void, recalibrate: @escaping () -> Void,
         permissions: @escaping () -> (Bool, Bool), requestMic: @escaping () -> Void,
         requestTyping: @escaping () -> Void, saveSettings: @escaping ([String: Any]) -> Void) {
        self.status = status; self.toggle = toggle; self.beginSetup = beginSetup
        self.endSetup = endSetup; self.enroll = enroll; self.cancelEnrollment = cancelEnrollment
        self.recalibrate = recalibrate; self.permissions = permissions
        self.requestMic = requestMic; self.requestTyping = requestTyping; self.saveSettings = saveSettings
        super.init()
        menu.delegate = self
        stateItem = NSMenuItem(title: "MyF5", action: nil, keyEquivalent: "")
        menu.addItem(stateItem); menu.addItem(.separator())
        toggleItem = action("Use Play/Pause for Music", #selector(toggleMode)); menu.addItem(toggleItem)
        journalItem = action("Switch to Journal Mode", #selector(toggleJournal)); menu.addItem(journalItem)
        menu.addItem(action("Open Latest Journal Entry", #selector(openJournal)))
        menu.addItem(action("Show Journal Folder", #selector(showJournalFolder)))
        menu.addItem(action("Welcome & Voice Setup…", #selector(showWelcome)))
        menu.addItem(action("Settings…", #selector(showSettings)))
        menu.addItem(action("Measure Room Noise Again", #selector(roomAgain)))
        menu.addItem(.separator())
        menu.addItem(action("Open MyF5 Folder", #selector(openFolder)))
        menu.addItem(action("Open Last Dictation", #selector(openLast)))
        menu.addItem(action("Installation & Customization Guide", #selector(openGuide)))
        item.menu = menu
        item.button?.title = " MyF5"
        item.button?.setAccessibilityLabel("MyF5 dictation controls")
        refresh()
    }
    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        value.target = self; return value
    }
    func refresh() {
        let now = status()
        stateItem.title = "MyF5 · " + now.description
        toggleItem.title = now.enabled ? "Use Play/Pause for Music" : "Use Play/Pause for MyF5"
        journalItem.title = Config.load().journalMode ? "Switch to Cursor Dictation" : "Switch to Journal Mode"
        let name = now.enabled ? "waveform" : "music.note"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: now.description)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "MyF5 — " + now.description
        refreshPermissions()
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    func dismissWelcome() {
        guard let window = welcomeWindow else { return }
        cancelEnrollment(); endSetup(false); completionClosing = true
        window.close(); cleanupWelcome()
    }
    @objc private func cancelWelcome() { dismissWelcome() }
    @objc private func toggleMode() { toggle(); refresh() }
    @objc private func toggleJournal() {
        guard !status().busy else { message("Finish this entry first", "Send or discard your current draft before switching modes."); return }
        saveSettings(["journalMode": !Config.load().journalMode]); refresh()
    }
    @objc private func openJournal() {
        let folder = ROOT.appendingPathComponent("Journal")
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let entries = (enumerator?.allObjects as? [URL]) ?? []
        guard let latest = entries.filter({ $0.pathExtension == "md" }).sorted(by: {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }).first else {
            message("Your journal is ready for its first entry", "Choose Journal mode, press Play/Pause, speak, and press again to save your entry."); return
        }
        NSWorkspace.shared.open([latest], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func showJournalFolder() {
        let folder = ROOT.appendingPathComponent("Journal")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.open(folder) }
        catch { message("Couldn’t open the journal", error.localizedDescription) }
    }
    @objc private func roomAgain() { recalibrate() }
    @objc private func openFolder() { NSWorkspace.shared.open(ROOT) }
    @objc private func openLast() {
        if FileManager.default.fileExists(atPath: LAST_DICTATION.path) { NSWorkspace.shared.open(LAST_DICTATION) }
        else { message("No saved dictation yet", "Your words will be saved here before MyF5 types them.") }
    }
    @objc private func openGuide() {
        NSWorkspace.shared.open([ROOT.appendingPathComponent("README.md")],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
    private func message(_ title: String, _ body: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = body
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private func window(_ title: String, width: CGFloat = 640, height: CGFloat = 650) -> NSWindow {
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        result.title = title; result.isReleasedWhenClosed = false; result.delegate = self
        result.center(); return result
    }
    private func column(in window: NSWindow) -> NSStackView {
        let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading
        view.spacing = 16; view.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.subviews.forEach { $0.removeFromSuperview() }
        window.contentView!.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            view.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            view.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)
        ])
        return view
    }
    private func label(_ text: String, size: CGFloat = 15, bold: Bool = false) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        value.isSelectable = true; value.translatesAutoresizingMaskIntoConstraints = false
        return value
    }
    private func addText(_ text: String, to stack: NSStackView, size: CGFloat = 15, bold: Bool = false) {
        let field = label(text, size: size, bold: bold); stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func button(_ title: String, _ selector: Selector) -> NSButton {
        NSButton(title: title, target: self, action: selector)
    }
    @objc func showWelcome() {
        if let existing = welcomeWindow { NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil); return }
        guard beginSetup() else {
            message("Finish this dictation first", "Send or discard your current draft, then open voice setup."); return
        }
        step = 0; enrollSucceeded = status().enrolled; completionClosing = false
        welcomeWindow = window("Welcome to MyF5")
        showStep()
        NSApp.activate(ignoringOtherApps: true); welcomeWindow?.makeKeyAndOrderFront(nil)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
    }
    private func showStep() {
        guard let welcomeWindow else { return }
        let col = column(in: welcomeWindow); stack = col
        let cross = button("×", #selector(cancelWelcome)); cross.isBordered = false
        cross.font = .systemFont(ofSize: 26); cross.toolTip = "Cancel setup"
        cross.setAccessibilityLabel("Cancel setup")
        cross.frame = NSRect(x: 600, y: 610, width: 32, height: 32)
        welcomeWindow.contentView?.addSubview(cross)
        promptView = nil
        progressLabel = nil; permissionLabel = nil; nextButton = nil; recordButton = nil
        addText("STEP \(step + 1) OF 4", to: col, size: 12, bold: true)
        switch step {
        case 0:
            addText("Hello, I’m MyF5.", to: col, size: 30, bold: true)
            addText("Your voice, turned into words wherever your cursor is. Press Play/Pause, wait for the tick, speak, and press it again to send. You can do this from a headset or another device with a media button.", to: col, size: 17)
            addText("I can show an editable draft, help you correct selected words by speaking, keep a local copy before typing, and start again when you log in. My menu bar switch gives the button back to music whenever you want.", to: col)
            addText("Journal mode saves dated text and your microphone recording locally instead of typing into another app. Switch modes from the menu bar whenever you want to capture an idea or reflect on your day.", to: col)
            addText("My listening stays on this Mac: Parakeet transcribes and DeepFilterNet3 reduces background noise. Voice matching is experimental and off by default. Nearby people may still be transcribed.", to: col)
            addText("Make me yours: choose your text size, spacing, review style, sounds, and whether I press Enter after typing. A coding assistant with local access can adapt my included source further to your preferences.", to: col)
            addText("Let’s set up permissions. You can use dictation immediately without enrolling a voice profile.", to: col)
            col.addArrangedSubview(button("Let’s get started", #selector(nextStep)))
        case 1:
            addText("Let macOS handle your microphone.", to: col, size: 27, bold: true)
            addText("I follow the input selected in macOS Sound settings, including changes between the built-in microphone and headphones. There is no separate microphone selector in MyF5.", to: col)
            addText("macOS needs two permissions. Microphone lets me listen; Accessibility lets me type your approved words. Open the settings below and enable MyF5 (older grants may say PTTHelper or K PTT).", to: col)
            let row = NSStackView(views: [button("Allow Microphone", #selector(allowMic)), button("Allow Typing", #selector(allowTyping))])
            row.spacing = 12; col.addArrangedSubview(row)
            let field = label(""); permissionLabel = field; col.addArrangedSubview(field)
            let next = button("Continue", #selector(nextStep)); nextButton = next; col.addArrangedSubview(next)
            refreshPermissions()
        case 2:
            addText("Reduce noise while you speak.", to: col, size: 27, bold: true)
            addText("Noise reduction is on by default. It helped preserve soft speech with loud video in our tests. It can still transcribe other people, especially when they speak loudly or overlap with you. Review the draft before sending.", to: col)
            addText("You can turn noise reduction off in Settings. Processing stays on this Mac; temporary audio files are deleted after processing. Voice matching is off in this release and no voice enrollment is required.", to: col)
            col.addArrangedSubview(button("Continue", #selector(nextStep)))
        default:
            addText("Ready to listen attentively.", to: col, size: 27, bold: true)
            addText("I follow the microphone selected by macOS. Wait for the tick before speaking. Journal mode saves your original audio and text locally.", to: col)
            addText("Try it:\n1. Open a document and place your cursor.\n2. Press Play/Pause and wait for the tick.\n3. Say a full sentence and review the draft.\n4. Press Play/Pause again, or Enter in the draft, to send.\n\nSelect a wrong word and speak a correction, or edit with your keyboard. × discards the draft. Shift+Enter adds a new line.", to: col)
            addText("For music: click MyF5 in the menu bar → Use Play/Pause for Music. That choice survives a restart. Switch back whenever you want to dictate.", to: col)
            addText("Try your keyboard and headphone buttons. Bluetooth button behavior can vary with the device and macOS version. Enter in the draft also finishes dictation.", to: col)
            let row = NSStackView(views: [button("Open TextEdit to try", #selector(openTextEdit)), button("Use MyF5", #selector(finishWelcome))])
            row.spacing = 12; col.addArrangedSubview(row)
        }
    }
    @objc private func nextStep() { step += 1; showStep() }
    @objc private func allowMic() { requestMic(); refreshPermissions() }
    @objc private func allowTyping() { requestTyping(); refreshPermissions() }
    private func refreshPermissions() {
        guard welcomeWindow != nil, step == 1 else { return }
        let p = permissions()
        permissionLabel?.stringValue = "Microphone: \(p.mic ? "allowed" : "needs permission") · Typing: \(p.typing ? "allowed" : "needs permission")"
        nextButton?.isEnabled = p.mic && p.typing
    }
    private func updatePrompt(_ heard: String?) {
        guard let view = promptView else { return }
        let pattern = try! NSRegularExpression(pattern: "\\S+")
        let ns = promptText as NSString
        let ranges = pattern.matches(in: promptText, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        if let heard {
            let expected = ranges.map { ns.substring(with: $0) }
            promptWordsRead = max(promptWordsRead, TeleprompterProgress.wordsRead(expected: expected, heard: heard))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10
        let rendered = NSMutableAttributedString(string: promptText, attributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        for range in ranges.prefix(promptWordsRead) {
            rendered.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
        }
        if promptWordsRead < ranges.count {
            rendered.addAttribute(.backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.16), range: ranges[promptWordsRead])
        }
        view.textStorage?.setAttributedString(rendered)
        if !ranges.isEmpty { view.scrollRangeToVisible(ranges[min(promptWordsRead, ranges.count-1)]) }
    }

    @objc private func startEnrollment() {
        if recording { cancelEnrollment(); recording = false; recordButton?.title = "Start again · 60 seconds"; progressLabel?.stringValue = "Recording discarded. Nothing was learned."; return }
        enrollmentSeconds = 0
        recording = true; nextButton?.isEnabled = false
        recordButton?.title = "Cancel recording"
        progressLabel?.stringValue = "Starting the microphone…"
        promptWordsRead = 0; updatePrompt(nil)
        enroll({ [weak self] seconds, level, words in
            guard let self else { return }
            self.enrollmentSeconds = max(self.enrollmentSeconds, seconds)
            if self.enrollmentSeconds > 60 {
                self.progressLabel?.stringValue = "Recording finished — checking and saving your voice profile…"
            } else {
                self.progressLabel?.stringValue = "● Recording \(min(60, Int(self.enrollmentSeconds))) / 60 seconds · \(level > -60 ? "Microphone receiving sound" : "Very quiet — speak naturally")"
            }
            if let words, !words.isEmpty { self.updatePrompt(words) }
        }, { [weak self] error in
            guard let self, self.welcomeWindow != nil else { return }
            self.recording = false; self.recordButton?.title = "Record again · 60 seconds"
            if let error {
                self.progressLabel?.stringValue = "Couldn’t save the profile: \(error)"
                self.nextButton?.isEnabled = self.enrollSucceeded
            } else {
                self.enrollSucceeded = true; self.nextButton?.isEnabled = true
                self.progressLabel?.stringValue = "Your voice profile is saved. I discarded the recording. You can continue."
            }
        })
    }
    @objc private func finishWelcome() {
        completionClosing = true; endSetup(true); welcomeWindow?.close(); cleanupWelcome()
    }
    @objc private func openTextEdit() {
        let practice = STATE.appendingPathComponent("MyF5 Practice.txt")
        if !FileManager.default.fileExists(atPath: practice.path) {
            try? Data().write(to: practice, options: .atomic)
        }
        finishWelcome()
        NSWorkspace.shared.open([practice],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
    private func cleanupWelcome() { permissionTimer?.invalidate(); permissionTimer = nil; welcomeWindow = nil; recording = false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === welcomeWindow {
            if !completionClosing { cancelEnrollment(); endSetup(false) }
            cleanupWelcome()
        }
        return true
    }
    @objc private func showSettings() {
        if welcomeWindow != nil { return }
        if let settingsWindow { NSApp.activate(ignoringOtherApps: true); settingsWindow.makeKeyAndOrderFront(nil); return }
        let window = window("MyF5 Settings", height: 690); settingsWindow = window
        let col = column(in: window); let config = Config.load(); settingsControls = [:]
        addText("Make MyF5 yours", to: col, size: 27, bold: true)
        addText("Microphone: follows macOS Sound settings automatically.", to: col)
        func slider(_ key: String, title: String, value: Double, min: Double, max: Double) {
            addText(title, to: col)
            let slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
            slider.frame.size.width = 480; slider.widthAnchor.constraint(equalToConstant: 480).isActive = true
            settingsControls[key] = slider; col.addArrangedSubview(slider)
        }
        slider("fontSize", title: "Draft text size · 12–40 points", value: Double(config.fontSize), min: 12, max: 40)
        slider("lineSpacing", title: "Line spacing · 0–18 points", value: Double(config.lineSpacing), min: 0, max: 18)
        let noiseURL = STATE.appendingPathComponent("noise-trial.json")
        let noiseData = try? Data(contentsOf: noiseURL)
        let noiseSettings = noiseData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let noiseEnabled = noiseSettings?["enabled"] as? Bool ?? true
        for (key, title, value) in [("noiseReduction","Reduce background noise",noiseEnabled), ("livePreview","Show live draft",config.livePreview), ("interactiveReview","Let me edit and review the draft",config.interactiveReview), ("feedbackSounds","Play the tick and feedback sounds",config.feedbackSounds), ("pressReturnAfterTyping","Press Enter in the destination app after typing",config.pressReturnAfterTyping)] {
            let check = NSButton(checkboxWithTitle: title, target: nil, action: nil); check.state = value ? .on : .off
            settingsControls[key] = check; col.addArrangedSubview(check)
        }
        addText("Changes apply to the next dictation. Noise reduction does not identify your voice; nearby people may be transcribed.", to: col, size: 13)
        let row = NSStackView(views: [button("Save settings", #selector(applySettings)), button("Open settings file", #selector(openConfig))]); row.spacing = 12; col.addArrangedSubview(row)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc private func openConfig() { NSWorkspace.shared.open(CONFIG_PATH) }
    @objc private func applySettings() {
        var values: [String: Any] = [:]
        for (key, control) in settingsControls {
            if let slider = control as? NSSlider { values[key] = slider.integerValue }
            else if let checkbox = control as? NSButton { values[key] = checkbox.state == .on }
        }
        saveSettings(values); settingsWindow?.close(); settingsWindow = nil
    }
}

/// Reading progress follows recognized words, never elapsed recording time.
enum TeleprompterProgress {
    static func wordsRead(expected: [String], heard: String) -> Int {
        func normalize(_ word: String) -> String {
            String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let target = expected.map(normalize)
        var next = 0, matches = 0
        for word in heard.split(whereSeparator: { $0.isWhitespace }).map({ normalize(String($0)) }) {
            guard !word.isEmpty, next < target.count else { continue }
            if let match = (next..<min(next+6, target.count)).first(where: { target[$0] == word }) {
                next = match+1; matches += 1
            }
        }
        return matches >= 3 ? next : 0
    }
}
