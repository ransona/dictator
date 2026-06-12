import AppKit
import AVFoundation
import Carbon
import Foundation
import Security

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

private final class KeychainStore {
    private let service = "com.ransona.dictator.mac"
    private let account = "openai-api-key"

    func loadApiKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }

        return value
    }

    func saveApiKey(_ apiKey: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(apiKey.utf8)
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
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

private final class OpenAIClient: @unchecked Sendable {
    private let transcriptionModel = "whisper-1"
    private let rewriteModel = "gpt-4o-mini"

    func transcribe(audioURL: URL, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(name: "model", value: transcriptionModel, boundary: boundary, to: &body)
        appendField(name: "response_format", value: "text", boundary: boundary, to: &body)
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
            throw NSError(domain: "OpenAI", code: status, userInfo: [NSLocalizedDescriptionKey: "OpenAI returned \(status): \(body)"])
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
private final class GlobalShortcut {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var escapeIsDown = false
    private var lastEscapeDown = Date.distantPast
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            escapeIsDown = event.type == .keyDown
            if escapeIsDown {
                lastEscapeDown = Date()
            }
        case kVK_F1 where event.type == .keyDown:
            if escapeIsDown || Date().timeIntervalSince(lastEscapeDown) < 0.45 {
                callback()
            }
        default:
            break
        }
    }
}

@MainActor
private final class OverlayWindowController {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Send", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    var sendRequested: (() -> Void)?
    var cancelRequested: (() -> Void)?
    var togglePauseRequested: (() -> Void)?

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 122),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictator"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        actionButton.target = self
        actionButton.action = #selector(send)
        actionButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"

        buttons.addArrangedSubview(actionButton)
        buttons.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(buttons)
        window.contentView = stack
    }

    func show(state: RecordingState, duration: TimeInterval) {
        update(state: state, duration: duration)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 32))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(state: RecordingState, duration: TimeInterval) {
        let seconds = Int(duration.rounded())
        switch state {
        case .idle:
            label.stringValue = "Ready"
        case .recording:
            label.stringValue = "Recording \(seconds)s"
        case .paused:
            label.stringValue = "Paused \(seconds)s"
        }
    }

    func setBusy(_ text: String) {
        label.stringValue = text
        actionButton.isEnabled = false
        cancelButton.isEnabled = false
    }

    func setError(_ text: String) {
        label.stringValue = text
        actionButton.isEnabled = true
        cancelButton.isEnabled = true
    }

    func hide() {
        actionButton.isEnabled = true
        cancelButton.isEnabled = true
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
    private let keychain = KeychainStore()
    private let historyStore = HistoryStore()
    private let recorder = AudioRecorder()
    private let openAI = OpenAIClient()
    private let overlay = OverlayWindowController()
    private var statusItem: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private var timer: Timer?
    private var isSending = false
    private var apiKey = ""
    private weak var targetApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        apiKey = keychain.loadApiKey()
        configureMenu()
        configureOverlay()
        requestMicrophonePermission()
        registerShortcut()
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
        menu.addItem(NSMenuItem(title: "Start Dictation", action: #selector(startDictation), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "OpenAI API Key...", action: #selector(editApiKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
            Task { @MainActor in self?.startDictation() }
        }
        shortcut?.register()
    }

    private func ensureApiKey() {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editApiKey()
        }
    }

    @objc private func editApiKey() {
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = apiKey

        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API key"
        alert.informativeText = "This is stored in your macOS Keychain and is only required once."
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            apiKey = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            keychain.saveApiKey(apiKey)
        }
    }

    @objc private func startDictation() {
        guard !isSending, recorder.state == .idle else { return }
        ensureApiKey()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        targetApp = NSWorkspace.shared.frontmostApplication

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
            let transcript = try await openAI.transcribe(audioURL: audioURL, apiKey: apiKey)
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
        } catch {
            overlay.setError(error.localizedDescription)
            alert(title: "Dictation failed", message: error.localizedDescription)
        }

        isSending = false
    }

    private func pasteIntoTarget(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        targetApp?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
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
