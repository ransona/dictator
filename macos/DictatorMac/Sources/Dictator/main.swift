import ApplicationServices
import AppKit
import AVFoundation
import Carbon
import Foundation

private enum RecordingState {
    case idle
    case recording
    case paused
}

private struct HistoryMessage: Codable {
    let id: String
    let text: String
    let createdAt: Date
}

private final class SettingsStore {
    private let directoryURL: URL
    private let apiKeyURL: URL
    private let transcriptionLanguageURL: URL

    init() {
        directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictator", isDirectory: true)
        apiKeyURL = directoryURL.appendingPathComponent("openai-api-key.txt")
        transcriptionLanguageURL = directoryURL.appendingPathComponent("transcription-language.txt")
    }

    func loadApiKey() -> String {
        guard let value = try? String(contentsOf: apiKeyURL, encoding: .utf8) else {
            return ""
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveApiKey(_ apiKey: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try apiKey.write(to: apiKeyURL, atomically: true, encoding: .utf8)
    }

    func loadTranscriptionLanguage() -> String {
        guard let value = try? String(contentsOf: transcriptionLanguageURL, encoding: .utf8) else {
            return "en"
        }

        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty ? "en" : code
    }

    func saveTranscriptionLanguage(_ languageCode: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try languageCode.write(to: transcriptionLanguageURL, atomically: true, encoding: .utf8)
    }
}

private final class HistoryStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictator", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [HistoryMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? decoder.decode([HistoryMessage].self, from: data) else {
            return []
        }

        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var items = load()
        items.insert(HistoryMessage(id: UUID().uuidString, text: trimmed, createdAt: Date()), at: 0)
        if items.count > 250 {
            items = Array(items.prefix(250))
        }
        save(items)
    }

    func clear() {
        save([])
    }

    private func save(_ items: [HistoryMessage]) {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
private final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var accumulatedDuration: TimeInterval = 0

    private(set) var state: RecordingState = .idle
    private(set) var fileURL: URL?

    var recordedDuration: TimeInterval {
        switch state {
        case .idle:
            return 0
        case .paused:
            return accumulatedDuration
        case .recording:
            return accumulatedDuration + Date().timeIntervalSince(startedAt ?? Date())
        }
    }

    func start() throws {
        guard state == .idle else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictator-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = self
        newRecorder.prepareToRecord()
        newRecorder.record()

        recorder = newRecorder
        fileURL = url
        startedAt = Date()
        accumulatedDuration = 0
        state = .recording
    }

    func pause() {
        guard state == .recording else { return }
        accumulatedDuration += Date().timeIntervalSince(startedAt ?? Date())
        recorder?.pause()
        startedAt = nil
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        recorder?.record()
        startedAt = Date()
        state = .recording
    }

    func stop(cancel: Bool) -> URL? {
        guard state != .idle else { return nil }
        if state == .recording {
            accumulatedDuration += Date().timeIntervalSince(startedAt ?? Date())
        }
        recorder?.stop()

        let url = fileURL
        recorder = nil
        startedAt = nil
        accumulatedDuration = 0
        state = .idle

        if cancel, let url {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return url
    }
}

private enum OpenAIError: LocalizedError {
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case let .requestFailed(statusCode, body):
            return "OpenAI returned \(statusCode): \(body)"
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case let .requestFailed(statusCode, _):
            return statusCode == 401
        }
    }
}

private final class OpenAIClient: @unchecked Sendable {
    private let transcriptionModel = "whisper-1"
    private let rewriteModel = "gpt-4o-mini"

    func transcribe(audioURL: URL, apiKey: String, languageCode: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(name: "model", value: transcriptionModel, boundary: boundary, to: &body)
        appendField(name: "response_format", value: "text", boundary: boundary, to: &body)
        appendField(name: "language", value: languageCode, boundary: boundary, to: &body)
        appendFile(name: "file", filename: "dictation.m4a", contentType: "audio/m4a", url: audioURL, boundary: boundary, to: &body)
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func postProcess(_ transcript: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": rewriteModel,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "developer", "content": Self.postProcessorInstruction],
                ["role": "user", "content": "Dictated text: \(transcript)"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let finalText = json["final_text"] as? String else {
            return transcript
        }

        let cleaned = Self.stripPlaceholderArtifacts(finalText)
        return cleaned.isEmpty ? transcript : cleaned
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            throw OpenAIError.requestFailed(statusCode: status, body: body)
        }
    }

    private func appendField(name: String, value: String, boundary: String, to body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }

    private func appendFile(name: String, filename: String, contentType: String, url: URL, boundary: String, to body: inout Data) {
        guard let fileData = try? Data(contentsOf: url) else { return }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
    }

    private static func stripPlaceholderArtifacts(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"\[(?:[^\]\r\n]{1,40})\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^[ \t]*(best regards|kind regards|sincerely|thanks|thank you)[ \t]*,\s*(\r?\n)?[ \t]*(your name|name|signature)[ \t]*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)\b(your name|your signature|insert name|add details here)\b"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: #"(\r?\n\s*){3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let postProcessorInstruction = """
You are a dictation post-processor.
Your job is to inspect the full dictated text and decide whether it contains a user instruction to transform the content before pasting it.

Supported intents include, but are not limited to:
- turn the content into an email
- summarize it
- format it
- rewrite it in a requested style, tone, or language

Rules:
- If the dictated text contains no clear transformation instruction, keep it verbatim.
- If it does contain a clear transformation instruction, return only the transformed result.
- Do not mention AI, LLMs, prompts, or that a transformation happened.
- Remove the instruction itself from the final output.
- The final text must contain no clues that it was generated by an LLM.
- Do not leave placeholders, template markers, bracketed fields, or prompts for the user to fill in later.
- Do not include things like [Name], [Your Name], [Company], [Date], [Signature], or notes telling the user to add details.
- Return fully usable text only.

Return JSON only with:
- transformed: boolean
- final_text: string
"""
}

@MainActor
private final class AccessibilityTarget {
    private let element: AXUIElement

    private init(element: AXUIElement) {
        self.element = element
    }

    static func promptForPermissionIfNeeded() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func captureFocusedElement() -> AccessibilityTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard result == .success, let element = value else {
            return nil
        }

        return AccessibilityTarget(element: element as! AXUIElement)
    }

    func insertText(_ text: String) -> Bool {
        focus()
        return false
    }

    func focus() {
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
    }
}

@MainActor
private final class GlobalShortcut {
    private static let doubleTapInterval: TimeInterval = 0.45

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var controlWasDown = false
    private var lastControlTap = Date.distantPast
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            return
        }

        let controlIsDown = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.control)

        if controlIsDown && !controlWasDown {
            let now = Date()
            if now.timeIntervalSince(lastControlTap) <= Self.doubleTapInterval {
                lastControlTap = .distantPast
                callback()
            } else {
                lastControlTap = now
            }
        }

        controlWasDown = controlIsDown
    }
}

@MainActor
private final class RecordingKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let isActive: () -> Bool
    private let send: () -> Void
    private let cancel: () -> Void

    init(isActive: @escaping () -> Bool, send: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.isActive = isActive
        self.send = send
        self.cancel = cancel
    }

    func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                _ = self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isActive() else { return false }

        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            send()
            return true
        default:
            return false
        }
    }
}

@MainActor
private final class OverlayWindowController {
    private let window: NSWindow
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    var sendRequested: (() -> Void)?
    var cancelRequested: (() -> Void)?
    var togglePauseRequested: (() -> Void)?

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 172, height: 54),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictator"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 172, height: 54)
        window.maxSize = NSSize(width: 172, height: 54)

        let contentView = NSView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = true
        spinner.startAnimation(nil)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        contentView.addSubview(stack)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    func show(state: RecordingState, duration: TimeInterval) {
        update(state: state, duration: duration)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 32))
        }
        window.orderFrontRegardless()
    }

    func update(state: RecordingState, duration: TimeInterval) {
        let seconds = Int(duration.rounded())
        switch state {
        case .idle:
            label.stringValue = "Ready"
            spinner.stopAnimation(nil)
        case .recording:
            label.stringValue = "\(seconds)s"
            spinner.startAnimation(nil)
        case .paused:
            label.stringValue = "Paused \(seconds)s"
            spinner.stopAnimation(nil)
        }
    }

    func setBusy(_ text: String) {
        label.stringValue = text
        spinner.startAnimation(nil)
    }

    func setError(_ text: String) {
        label.stringValue = text
        spinner.stopAnimation(nil)
    }

    func hide() {
        spinner.stopAnimation(nil)
        window.orderOut(nil)
    }

    @objc private func send() {
        sendRequested?()
    }

    @objc private func cancel() {
        cancelRequested?()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let historyStore = HistoryStore()
    private let recorder = AudioRecorder()
    private let openAI = OpenAIClient()
    private let overlay = OverlayWindowController()
    private var statusItem: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private var timer: Timer?
    private var isSending = false
    private var apiKey = ""
    private var transcriptionLanguage = "en"
    private var targetApp: NSRunningApplication?
    private var targetElement: AccessibilityTarget?
    private var recordingKeyMonitor: RecordingKeyMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        apiKey = settingsStore.loadApiKey()
        transcriptionLanguage = settingsStore.loadTranscriptionLanguage()
        configureMenu()
        configureOverlay()
        requestMicrophonePermission()
        AccessibilityTarget.promptForPermissionIfNeeded()
        registerShortcut()
        registerRecordingKeyMonitor()
        ensureApiKey()

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.overlay.update(state: self.recorder.state, duration: self.recorder.recordedDuration)
            }
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Dictator"

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Start Dictation", action: #selector(startDictation)))
        menu.addItem(menuItem(title: "OpenAI API Key...", action: #selector(editApiKey)))
        menu.addItem(menuItem(title: "Transcription Language...", action: #selector(editTranscriptionLanguage)))
        menu.addItem(menuItem(title: "Show History", action: #selector(showHistory)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func configureOverlay() {
        overlay.sendRequested = { [weak self] in
            Task { @MainActor in await self?.sendRecording() }
        }
        overlay.cancelRequested = { [weak self] in
            Task { @MainActor in await self?.cancelRecording() }
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                Task { @MainActor in
                    self.alert(title: "Microphone permission required", message: "Enable microphone access for Dictator in System Settings.")
                }
            }
        }
    }

    private func registerShortcut() {
        shortcut = GlobalShortcut { [weak self] in
            Task { @MainActor in await self?.toggleDictationFromShortcut() }
        }
        shortcut?.register()
    }

    private func registerRecordingKeyMonitor() {
        recordingKeyMonitor = RecordingKeyMonitor(
            isActive: { [weak self] in
                guard let self else { return false }
                return self.recorder.state != .idle && !self.isSending
            },
            send: { [weak self] in
                Task { @MainActor in await self?.sendRecording() }
            },
            cancel: { [weak self] in
                Task { @MainActor in await self?.cancelRecording() }
            }
        )
        recordingKeyMonitor?.register()
    }

    private func toggleDictationFromShortcut() async {
        if recorder.state == .idle {
            startDictation()
        } else {
            await sendRecording()
        }
    }

    @discardableResult
    private func ensureApiKey() -> Bool {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editApiKey()
        }

        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func editApiKey() {
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = apiKey

        let keyAlert = NSAlert()
        keyAlert.messageText = "Enter OpenAI API key"
        keyAlert.informativeText = "This is stored in ~/Library/Application Support/Dictator/openai-api-key.txt."
        keyAlert.accessoryView = input
        keyAlert.addButton(withTitle: "Save")
        keyAlert.addButton(withTitle: "Cancel")
        keyAlert.window.initialFirstResponder = input

        if keyAlert.runModal() == .alertFirstButtonReturn {
            let newApiKey = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try settingsStore.saveApiKey(newApiKey)
                apiKey = newApiKey
            } catch {
                alert(title: "API key not saved", message: error.localizedDescription)
            }
        }
    }

    @objc private func editTranscriptionLanguage() {
        let languageOptions = [
            ("English", "en"),
            ("Spanish", "es"),
            ("French", "fr"),
            ("German", "de"),
            ("Italian", "it"),
            ("Portuguese", "pt"),
            ("Dutch", "nl"),
            ("Welsh", "cy")
        ]

        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 28, width: 360, height: 26), pullsDown: false)
        for option in languageOptions {
            popUp.addItem(withTitle: "\(option.0) (\(option.1))")
            popUp.lastItem?.representedObject = option.1
        }

        let customField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        customField.placeholderString = "ISO language code, e.g. en"
        customField.stringValue = transcriptionLanguage

        if let index = languageOptions.firstIndex(where: { $0.1 == transcriptionLanguage }) {
            popUp.selectItem(at: index)
        }

        popUp.target = self
        popUp.action = #selector(languagePopUpChanged(_:))

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 58))
        accessoryView.addSubview(popUp)
        accessoryView.addSubview(customField)

        let languageAlert = NSAlert()
        languageAlert.messageText = "Transcription language"
        languageAlert.informativeText = "Dictator passes this language code to OpenAI transcription instead of allowing auto-detection."
        languageAlert.accessoryView = accessoryView
        languageAlert.addButton(withTitle: "Save")
        languageAlert.addButton(withTitle: "Cancel")
        languageAlert.window.initialFirstResponder = customField

        if languageAlert.runModal() == .alertFirstButtonReturn {
            let code = customField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !code.isEmpty else {
                alert(title: "Language not saved", message: "Enter a language code such as en, es, fr, or de.")
                return
            }

            do {
                try settingsStore.saveTranscriptionLanguage(code)
                transcriptionLanguage = code
            } catch {
                alert(title: "Language not saved", message: error.localizedDescription)
            }
        }
    }

    @objc private func languagePopUpChanged(_ sender: NSPopUpButton) {
        guard let code = sender.selectedItem?.representedObject as? String,
              let customField = sender.superview?.subviews.compactMap({ $0 as? NSTextField }).first else {
            return
        }

        customField.stringValue = code
    }

    @objc private func startDictation() {
        guard !isSending, recorder.state == .idle else { return }
        guard ensureApiKey() else { return }

        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApp = frontmostApp
        }
        targetElement = AccessibilityTarget.captureFocusedElement()

        do {
            try recorder.start()
            overlay.show(state: recorder.state, duration: recorder.recordedDuration)
        } catch {
            alert(title: "Recording failed", message: error.localizedDescription)
        }
    }

    private func cancelRecording() async {
        _ = recorder.stop(cancel: true)
        overlay.hide()
    }

    private func sendRecording() async {
        guard recorder.state != .idle, !isSending else { return }
        isSending = true
        overlay.setBusy("Transcribing...")

        guard let audioURL = recorder.stop(cancel: false) else {
            overlay.hide()
            isSending = false
            return
        }

        do {
            let transcript = try await openAI.transcribe(audioURL: audioURL, apiKey: apiKey, languageCode: transcriptionLanguage)
            try? FileManager.default.removeItem(at: audioURL)
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                overlay.hide()
                alert(title: "No transcript returned", message: "OpenAI returned empty text for that recording.")
                isSending = false
                return
            }

            overlay.setBusy("Processing text...")
            let finalText = try await openAI.postProcess(transcript, apiKey: apiKey)
            historyStore.add(finalText)
            overlay.hide()
            pasteIntoTarget(finalText)
        } catch let error as OpenAIError where error.isAuthenticationFailure {
            overlay.hide()
            alert(title: "OpenAI API key required", message: "Enter or update your OpenAI API key to continue.")
            editApiKey()
        } catch {
            overlay.setError(error.localizedDescription)
            alert(title: "Dictation failed", message: error.localizedDescription)
        }

        isSending = false
    }

    private func pasteIntoTarget(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)

        guard let targetApp else {
            alert(title: "Transcript copied", message: "Dictator could not identify the previous app. The transcript is on the clipboard.")
            return
        }

        targetApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let targetElement = targetElement
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            _ = targetElement?.insertText(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Self.sendPasteShortcut(to: targetApp.processIdentifier)
            }
        }
    }

    private static func sendPasteShortcut(to processIdentifier: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

        commandDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        postKeyEvent(commandDown, to: processIdentifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            postKeyEvent(vDown, to: processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                postKeyEvent(vUp, to: processIdentifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    postKeyEvent(commandUp, to: processIdentifier)
                }
            }
        }
    }

    private static func postKeyEvent(_ event: CGEvent?, to processIdentifier: pid_t) {
        guard let event else { return }
        event.postToPid(processIdentifier)
    }

    @objc private func showHistory() {
        let items = historyStore.load()
        let text = items.prefix(30).map { item in
            let preview = item.text.replacingOccurrences(of: "\n", with: " ")
            return "\(item.createdAt.formatted(date: .abbreviated, time: .shortened))\n\(preview)"
        }.joined(separator: "\n\n")

        let alert = NSAlert()
        alert.messageText = "Dictation History"
        alert.informativeText = text.isEmpty ? "No dictation history yet." : text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Clear History")
        if alert.runModal() == .alertSecondButtonReturn {
            historyStore.clear()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
