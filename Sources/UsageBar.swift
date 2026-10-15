import AppKit
import Foundation
import SwiftUI

private enum CodexError: LocalizedError {
    case codexNotFound
    case serverStopped
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound: return "Codex CLI not found. Install the ChatGPT or Codex app."
        case .serverStopped: return "Connection to Codex App Server ended."
        case .invalidResponse: return "Codex returned an invalid response."
        case .server(let message): return message
        }
    }
}

struct LimitWindow {
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?

    init?(json: [String: Any]?) {
        guard let json, let usedPercent = json["usedPercent"] as? Int else { return nil }
        self.usedPercent = usedPercent
        resetsAt = (json["resetsAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        durationMinutes = json["windowDurationMins"] as? Int
    }

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var isWeekly: Bool { (durationMinutes ?? 0) >= 1_440 }
}

struct UsageSnapshot {
    let weekly: LimitWindow?
    let planType: String?
    let updatedAt = Date()

    init(result: [String: Any]) throws {
        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw CodexError.invalidResponse
        }
        let windows = [rateLimits["primary"], rateLimits["secondary"]]
            .compactMap { LimitWindow(json: $0 as? [String: Any]) }
        weekly = windows.first(where: \.isWeekly)
        planType = rateLimits["planType"] as? String
    }

    /// App-server plan ids are internal names; map the known ones to what the subscription page shows.
    var planLabel: String? {
        guard let planType, !planType.isEmpty else { return nil }
        switch planType.lowercased() {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        default: return planType.prefix(1).uppercased() + planType.dropFirst()
        }
    }
}

private final class CodexAppServerClient {
    typealias Completion = (Result<UsageSnapshot, Error>) -> Void

    private enum State {
        case stopped
        case initializing
        case ready
    }

    private let queue = DispatchQueue(label: "local.usage-bar.app-server")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var nextRequestID = 1
    private var state: State = .stopped
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var pendingUsageRequests: [Completion] = []

    func fetchUsage(completion: @escaping Completion) {
        queue.async {
            switch self.state {
            case .stopped:
                self.pendingUsageRequests.append(completion)
                self.startServer()
            case .initializing:
                self.pendingUsageRequests.append(completion)
            case .ready:
                self.requestUsage(completion: completion)
            }
        }
    }

    func stop() {
        queue.sync {
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.process?.terminationHandler = nil
            if self.process?.isRunning == true {
                self.process?.terminate()
                self.process?.waitUntilExit()
            }
            self.process = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.state = .stopped
        }
    }

    private func startServer() {
        guard let executable = Self.findCodexExecutable() else {
            failAll(with: CodexError.codexNotFound)
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleTermination() }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.state = .initializing
            sendRequest(
                method: "initialize",
                params: ["clientInfo": ["name": "usage-bar", "title": "Usage Bar", "version": "2.0.0"]]
            ) { result in
                switch result {
                case .success:
                    self.sendNotification(method: "initialized")
                    self.state = .ready
                    let pending = self.pendingUsageRequests
                    self.pendingUsageRequests.removeAll()
                    pending.forEach { self.requestUsage(completion: $0) }
                case .failure(let error):
                    self.failAll(with: error)
                }
            }
        } catch {
            failAll(with: error)
        }
    }

    private func requestUsage(completion: @escaping Completion) {
        sendRequest(method: "account/rateLimits/read", params: nil) { result in
            completion(result.flatMap { json in Result { try UsageSnapshot(result: json) } })
        }
    }

    private func sendRequest(
        method: String,
        params: Any?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let id = nextRequestID
        nextRequestID += 1
        callbacks[id] = completion
        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }
        writeJSON(payload)
    }

    private func sendNotification(method: String) {
        writeJSON(["method": method])
    }

    private func writeJSON(_ value: [String: Any]) {
        guard let handle = inputPipe?.fileHandleForWriting,
              var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            failAll(with: error)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int,
                  let callback = callbacks.removeValue(forKey: id) else { continue }

            if let errorObject = object["error"] as? [String: Any] {
                callback(.failure(CodexError.server(errorObject["message"] as? String ?? "Codex App Server error")))
            } else if let result = object["result"] as? [String: Any] {
                callback(.success(result))
            } else {
                callback(.failure(CodexError.invalidResponse))
            }
        }
    }

    private func handleTermination() {
        guard state != .stopped else { return }
        process = nil
        inputPipe = nil
        outputPipe = nil
        state = .stopped
        failAll(with: CodexError.serverStopped)
    }

    private func failAll(with error: Error) {
        let requestCallbacks = callbacks.values
        callbacks.removeAll()
        let usageCallbacks = pendingUsageRequests
        pendingUsageRequests.removeAll()
        state = .stopped
        requestCallbacks.forEach { $0(.failure(error)) }
        usageCallbacks.forEach { $0(.failure(error)) }
    }

    private static func findCodexExecutable() -> URL? {
        if let overridePath = ProcessInfo.processInfo.environment["CODEX_PATH"],
           FileManager.default.isExecutableFile(atPath: overridePath) {
            return URL(fileURLWithPath: overridePath)
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            home + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.local/bin/codex"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = CodexAppServerClient()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var claudeTimer: Timer?
    private var snapshot: UsageSnapshot?
    private var claudeSnapshot: ClaudeUsageSnapshot?
    private var errorMessage: String?
    private var claudeError: String?
    private var claudeConnected = false
    private var claudePlan: String?
    private var claudeCLIError: String?
    private var claudeCLIRefreshing = false
    private var lastClaudeCLIRefresh = Date.distantPast
    private var codexRefreshing = false
    private var desktopWindow: DesktopWindow?
    private static let pinnedKey = "pinnedToDesktop"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleDashboard)
        popover.behavior = .transient
        if UserDefaults.standard.bool(forKey: Self.pinnedKey) { showDesktopWindow() }
        updateDisplay()
        refresh(manual: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh(manual: false)
        }
        // Claude data is a small local file (written by the status line or `/usage`); re-reading it is cheap.
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reloadClaude()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        claudeTimer?.invalidate()
        client.stop()
    }

    private func reloadClaude() {
        // Either source is enough: the `claude` CLI for auto refresh, or the status line connection.
        claudeConnected = ClaudeBridge.isConnected || ClaudeBridge.findCLI() != nil
        claudeSnapshot = ClaudeBridge.load()
        claudeError = claudeSnapshot == nil && claudeConnected
            ? claudeCLIError ?? (claudeCLIRefreshing ? nil : "Waiting for Claude Code usage data.")
            : nil
        updateDisplay()
    }

    /// `/usage` takes a couple of seconds, so it runs at launch, on manual refresh and every 5 minutes.
    private func refreshClaudeFromCLI(manual: Bool) {
        guard !claudeCLIRefreshing,
              manual || Date().timeIntervalSince(lastClaudeCLIRefresh) >= 290,
              ClaudeBridge.findCLI() != nil else { return }
        claudeCLIRefreshing = true
        lastClaudeCLIRefresh = Date()
        ClaudeBridge.refreshFromCLI { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.claudeCLIRefreshing = false
                self.claudeCLIError = error
                self.reloadClaude()
            }
        }
    }

    private func connectClaude() {
        do {
            try ClaudeBridge.connect()
        } catch {
            claudeError = "Could not update ~/.claude/settings.json: \(error.localizedDescription)"
        }
        reloadClaude()
    }

    private func refresh(manual: Bool) {
        claudePlan = ClaudeBridge.planLabel()
        refreshClaudeFromCLI(manual: manual)
        reloadClaude()
        if !codexRefreshing {
            codexRefreshing = true
            client.fetchUsage { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.codexRefreshing = false
                    switch result {
                    case .success(let snapshot):
                        self.snapshot = snapshot
                        self.errorMessage = nil
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                    self.updateDisplay()
                }
            }
        }
        updateDisplay()
    }

    @objc private func toggleDashboard() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateDisplay()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateDisplay() {
        statusItem.button?.title = combinedStatusTitle(codex: snapshot, claude: claudeSnapshot)
        statusItem.button?.toolTip = "Remaining: X Codex weekly · A Claude 5-hour | weekly"
        let dashboard = UsageDashboard(
            codex: snapshot,
            claude: claudeSnapshot,
            codexError: errorMessage,
            claudeError: claudeError,
            refreshing: codexRefreshing,
            claudePlan: claudePlan,
            claudeConnected: claudeConnected,
            onConnectClaude: { [weak self] in self?.connectClaude() },
            pinned: desktopWindow != nil,
            onRefresh: { [weak self] in self?.refresh(manual: true) },
            onTogglePin: { [weak self] in self?.togglePin() },
            onQuit: { NSApp.terminate(nil) }
        )
        if let window = desktopWindow, let hosting = window.hosting {
            var pinnedDashboard = dashboard
            pinnedDashboard.pinned = true
            hosting.rootView = pinnedDashboard
            window.fit(size: hosting.fittingSize)
        }
        if let hosting = popover.contentViewController as? NSHostingController<UsageDashboard> {
            hosting.rootView = dashboard
        } else {
            popover.contentViewController = NSHostingController(rootView: dashboard)
        }
        // Size the popover to the dashboard's full height so two-line reset labels are never clipped.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
    }

    private func togglePin() {
        if let window = desktopWindow {
            window.saveFrame(usingName: DesktopWindow.frameName)
            window.orderOut(nil)
            desktopWindow = nil
        } else {
            popover.performClose(nil)
            showDesktopWindow()
        }
        UserDefaults.standard.set(desktopWindow != nil, forKey: Self.pinnedKey)
        updateDisplay()
    }

    private func showDesktopWindow() {
        let window = DesktopWindow()
        let hosting = NSHostingView(rootView: UsageDashboard(
            codex: nil, claude: nil, codexError: nil, claudeError: nil,
            refreshing: false, onRefresh: {}, onQuit: {}
        ))
        window.setHosting(hosting)
        if !window.setFrameUsingName(DesktopWindow.frameName), let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.maxY - 20))
        }
        window.fit(size: hosting.fittingSize)
        window.setFrameAutosaveName(DesktopWindow.frameName)
        window.orderFront(nil)
        desktopWindow = window
    }
}

/// Borderless window that sits just above the desktop icons, below every app window,
/// and stays put across Spaces and "Show Desktop". Drag anywhere on its background to move it.
private final class DesktopWindow: NSWindow {
    static let frameName = "UsageBarDesktopWindow"

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 390, height: 480),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    private(set) var hosting: NSHostingView<UsageDashboard>?

    /// Blurred, translucent rounded background like a macOS widget, with the dashboard on top.
    func setHosting(_ view: NSHostingView<UsageDashboard>) {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            view.topAnchor.constraint(equalTo: effect.topAnchor),
            view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        contentView = effect
        hosting = view
    }

    /// Resize keeping the top-left corner, then pull the window fully onto the screen it is on.
    func fit(size: NSSize) {
        var frame = NSRect(x: self.frame.minX, y: self.frame.maxY - size.height,
                           width: size.width, height: size.height)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let visible = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        setFrame(frame, display: true)
    }
}

@main
private enum UsageBarApp {
    static func main() {
        if CommandLine.arguments.contains("--statusline") {
            ClaudeBridge.runStatusLine()
        }
        for (flag, action) in [("--connect-claude", ClaudeBridge.connect),
                               ("--disconnect-claude", ClaudeBridge.disconnect)]
        where CommandLine.arguments.contains(flag) {
            do {
                try action()
                print("OK \(flag)")
                exit(0)
            } catch {
                fputs("ERROR \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-dashboard"),
           CommandLine.arguments.indices.contains(index + 1) {
            renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if CommandLine.arguments.contains("--combined-usage-test") {
            runParsingTest()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func sampleData() throws -> (UsageSnapshot, ClaudeUsageSnapshot) {
        let codex = try UsageSnapshot(result: ["rateLimits": [
            "primary": ["usedPercent": 40, "windowDurationMins": 10080,
                        "resetsAt": Int(Date().timeIntervalSince1970) + 3 * 86_400],
            "planType": "prolite"
        ]])
        let now = Date().timeIntervalSince1970
        let claude = ClaudeUsageSnapshot(rateLimits: [
            "five_hour": ["used_percentage": 65.0, "resets_at": now + 7_200],
            "seven_day": ["used_percentage": 34, "resets_at": now + 5 * 86_400]
        ], capturedAt: Date())!
        return (codex, claude)
    }

    private static func renderPreview(to url: URL) -> Never {
        _ = NSApplication.shared
        let (codex, claude) = try! sampleData()
        let pinned = CommandLine.arguments.contains("--pinned")
        let view = NSHostingView(rootView: UsageDashboard(
            codex: codex, claude: claude, codexError: nil, claudeError: nil,
            refreshing: false, pinned: pinned, onRefresh: {}, onQuit: {}
        ).background(pinned ? Color(white: 0.22) : .clear))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
        exit(0)
    }

    private static func runParsingTest() -> Never {
        do {
            let (codex, claude) = try sampleData()
            precondition(combinedStatusTitle(codex: codex, claude: claude) == "X 60% A 35%|66%")
            precondition(combinedStatusTitle(codex: codex, claude: nil) == "X 60% A —|—")
            precondition(codex.planLabel == "Pro 100")
            precondition(claude.fiveHour?.resetsAt != nil && claude.weekly?.resetsAt != nil)
            let now = Date()
            precondition(dailyAverageRemaining(remaining: 60, resetsAt: now.addingTimeInterval(3 * 86_400), now: now) == 20)
            precondition(dailyAverageRemaining(remaining: 60, resetsAt: now.addingTimeInterval(3_600), now: now) == 60)
            precondition(dailyAverageRemaining(remaining: 60, resetsAt: nil, now: now) == nil)
            let zero = ClaudeUsageSnapshot(rateLimits: ["five_hour": ["used_percentage": 0]], capturedAt: now)
            precondition(zero?.fiveHour?.remainingPercent == 100 && zero?.weekly == nil)
            precondition(ClaudeLimitWindow(json: ["used_percentage": -1]) == nil)
            precondition(ClaudeLimitWindow(json: ["used_percentage": 101]) == nil)
            let expired = ClaudeLimitWindow(json: ["used_percentage": 80,
                                                  "resets_at": now.timeIntervalSince1970 - 60], now: now)
            precondition(expired?.remainingPercent == 100 && expired?.resetsAt == nil)
            precondition(ClaudeUsageSnapshot(rateLimits: [:], capturedAt: now) == nil)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
            let octNoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 1, minute: 37, second: 12))!
            let output = """
            Current session: 67% used · resets Oct 14 at 2:50am (Australia/Sydney)
            Current week (all models): 13.5% used · resets Oct 17 at 8pm (Australia/Sydney)
            """
            let parsed = ClaudeBridge.parseUsageOutput(output, now: octNoon)
            let five = parsed?["five_hour"] as? [String: Any]
            let week = parsed?["seven_day"] as? [String: Any]
            precondition(five?["used_percentage"] as? Double == 67 && week?["used_percentage"] as? Double == 13.5)
            precondition(five?["resets_at"] as? Double
                == calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 2, minute: 50))!
                    .timeIntervalSince1970)
            precondition(week?["resets_at"] as? Double
                == calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 20))!.timeIntervalSince1970)
            let newYear = ClaudeBridge.parseUsageOutput("Current week (all models): 5% used · resets Jan 2 at 9am (UTC)",
                                                        now: calendar.date(from: DateComponents(year: 2026, month: 12, day: 30))!)
            precondition(((newYear?["seven_day"] as? [String: Any])?["resets_at"] as? Double).map {
                Date(timeIntervalSince1970: $0) > calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
            } == true)
            precondition(ClaudeBridge.parseUsageOutput("Not logged in", now: now) == nil)
            precondition(ClaudeBridge.planLabel(organizationType: "claude_pro", rateLimitTier: "default_claude_ai") == "Pro")
            precondition(ClaudeBridge.planLabel(organizationType: "claude_max",
                                                rateLimitTier: "default_claude_max_20x") == "Max 20x")
            precondition(ClaudeBridge.planLabel(organizationType: "claude_team", rateLimitTier: nil) == "Team")
            print("OK combined-usage parsing, plan label, daily average, expired window, missing data")
            exit(0)
        } catch {
            fputs("ERROR \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
