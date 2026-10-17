import AppKit
import CoreFoundation
import Foundation
import SwiftUI

private enum CodexError: LocalizedError {
    case codexNotFound
    case serverStopped(Int32)
    case invalidResponse
    case requestTimedOut
    case authenticationRequired
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .codexNotFound: return "Codex CLI not found. Install the ChatGPT or Codex app."
        case .serverStopped(let status): return "Codex connection ended (exit \(status)). Try Refresh."
        case .invalidResponse: return "Codex returned an invalid response."
        case .requestTimedOut: return "Codex did not respond within 20 seconds. Try Refresh."
        case .authenticationRequired: return "Codex sign-in is unavailable. Check sign-in in the Codex app."
        case .server(let code): return "Codex usage request failed (code \(code)). Try Refresh."
        }
    }
}

struct LimitWindow {
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?

    init?(json: [String: Any]?) {
        guard let json, let usedPercent = json["usedPercent"] as? Int,
              let number = json["usedPercent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), usedPercent >= 0 else { return nil }
        self.usedPercent = usedPercent
        resetsAt = (json["resetsAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        durationMinutes = json["windowDurationMins"] as? Int
    }

    var remainingPercent: Int { 100 - min(100, usedPercent) }
    var isWeekly: Bool { durationMinutes == 10_080 }
}

struct UsageSnapshot {
    let weekly: LimitWindow?
    let planType: String?
    let updatedAt: Date

    init(result: [String: Any], updatedAt: Date = Date()) throws {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let legacy = result["rateLimits"] as? [String: Any]
        guard let rateLimits = (byID?["codex"] as? [String: Any]) ?? legacy,
              rateLimits["limitId"] as? String == nil || rateLimits["limitId"] as? String == "codex" else {
            throw CodexError.invalidResponse
        }
        let windows = [rateLimits["primary"], rateLimits["secondary"]]
            .compactMap { LimitWindow(json: $0 as? [String: Any]) }
        weekly = windows.first(where: \.isWeekly)
        planType = rateLimits["planType"] as? String
        self.updatedAt = updatedAt
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
    private var timeouts: [Int: DispatchWorkItem] = [:]
    private let requestTimeout: TimeInterval
    private let executableOverride: URL?

    init(requestTimeout: TimeInterval = 20, executable: URL? = nil) {
        self.requestTimeout = requestTimeout
        executableOverride = executable
    }

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
            self.resetServer()
            self.callbacks.removeAll()
            self.pendingUsageRequests.removeAll()
        }
    }

    private func startServer() {
        guard let executable = executableOverride ?? Self.findCodexExecutable() else {
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

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let process else { return }
            self?.queue.async {
                guard self?.process === process else { return }
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                guard self?.process === terminated else { return }
                self?.failAll(with: CodexError.serverStopped(terminated.terminationStatus))
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.state = .initializing
            sendRequest(
                method: "initialize",
                params: ["clientInfo": ["name": "usage-bar", "title": "Usage Bar", "version": "2.0.2"]]
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
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.callbacks[id] != nil else { return }
            self?.failAll(with: CodexError.requestTimedOut)
        }
        timeouts[id] = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
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
            timeouts.removeValue(forKey: id)?.cancel()

            if let errorObject = object["error"] as? [String: Any] {
                // Show a fixed diagnosis and code, never arbitrary server text or credentials.
                let message = (errorObject["message"] as? String ?? "").lowercased()
                let authError = ["not logged in", "not authenticated", "unauthorized", "sign in", "authentication"]
                    .contains(where: message.contains)
                callback(.failure(authError ? CodexError.authenticationRequired
                                  : CodexError.server(errorObject["code"] as? Int ?? -1)))
            } else if let result = object["result"] as? [String: Any] {
                callback(.success(result))
            } else {
                callback(.failure(CodexError.invalidResponse))
            }
        }
    }

    private func resetServer() {
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        buffer.removeAll()
        state = .stopped
    }

    private func failAll(with error: Error) {
        let requestCallbacks = Array(callbacks.values)
        callbacks.removeAll()
        let usageCallbacks = pendingUsageRequests
        pendingUsageRequests.removeAll()
        resetServer()
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
        let codexDisplay = CodexUsagePresentation(snapshot: snapshot, error: errorMessage, refreshing: codexRefreshing)
        statusItem.button?.title = combinedStatusTitle(codex: snapshot, claude: claudeSnapshot,
                                                       codexError: errorMessage, refreshing: codexRefreshing)
        statusItem.button?.toolTip = "Codex: \(codexDisplay.message) \(codexResetDescription(codexDisplay.reset))"
            + "\nA: Claude 5-hour | weekly remaining"
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
        let (sample, claude) = try! sampleData()
        var codex: UsageSnapshot? = sample
        var error: String?
        var refreshing = false
        if let index = CommandLine.arguments.firstIndex(of: "--codex-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let scenario = CommandLine.arguments[index + 1]
            let now = Date()
            let reset = now.addingTimeInterval(scenario == "reset-passed" ? -60 : 3 * 86_400)
            let result: [String: Any] = ["rateLimits": ["primary": [
                "usedPercent": scenario == "available" ? 40 : (scenario == "low" ? 99 : 100), "windowDurationMins": 10_080,
                "resetsAt": Int(reset.timeIntervalSince1970)
            ], "planType": "prolite"]]
            codex = try! UsageSnapshot(result: result,
                                       updatedAt: scenario == "stale" ? now.addingTimeInterval(-600) : now)
            if scenario == "error" { error = CodexError.requestTimedOut.localizedDescription }
            if scenario == "unavailable" { codex = try! UsageSnapshot(result: ["rateLimits": [:]]) }
            if scenario == "loading" { codex = nil; refreshing = true }
        }
        let pinned = CommandLine.arguments.contains("--pinned")
        let view = NSHostingView(rootView: UsageDashboard(
            codex: codex, claude: claude, codexError: error, claudeError: nil,
            refreshing: refreshing, pinned: pinned, onRefresh: {}, onQuit: {}
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
            try runCodexUsageTests()
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

    private static func runCodexUsageTests() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 86_400)
        func window(_ used: Any, minutes: Int = 10_080) -> [String: Any] {
            ["usedPercent": used, "windowDurationMins": minutes, "resetsAt": Int(reset.timeIntervalSince1970)]
        }
        func snapshot(_ weekly: [String: Any], updatedAt: Date? = nil) throws -> UsageSnapshot {
            try UsageSnapshot(result: ["rateLimits": ["primary": weekly]], updatedAt: updatedAt ?? now)
        }
        func display(_ value: UsageSnapshot?, error: String? = nil, refreshing: Bool = false,
                     at time: Date? = nil) -> CodexUsagePresentation {
            CodexUsagePresentation(snapshot: value, error: error, refreshing: refreshing, now: time ?? now)
        }
        let exhausted = try snapshot(window(100))
        let available = try snapshot(window(40))
        precondition(display(exhausted).status == .exhausted && display(exhausted).remainingPercent == 0)
        precondition(display(exhausted).message == "Weekly quota exhausted.")
        precondition(combinedStatusTitle(codex: exhausted, claude: nil, now: now) == "X 0%! A —|—")
        precondition(display(available).status == .available && display(available).remainingPercent == 60)
        let full = try snapshot(window(0))
        precondition(full.weekly?.remainingPercent == 100)
        // Over-limit readings remain exhausted; clamp before subtracting to avoid integer overflow.
        precondition(LimitWindow(json: window(Int.max))?.remainingPercent == 0)
        precondition(LimitWindow(json: window(-1)) == nil)
        for invalid in [NSNull(), "0", 0.5] as [Any] {
            let value = try snapshot(window(invalid))
            precondition(value.weekly == nil)
        }
        let boolean = try JSONSerialization.jsonObject(with: Data("{\"usedPercent\":true,\"windowDurationMins\":10080}".utf8)) as! [String: Any]
        precondition(LimitWindow(json: boolean) == nil)
        let missingPercent = try snapshot(["windowDurationMins": 10_080])
        let dailyOnly = try snapshot(window(40, minutes: 1_440))
        precondition(display(missingPercent).status == .unavailable)
        precondition(display(dailyOnly).status == .unavailable)
        precondition(display(nil).status == .unavailable && display(nil).remainingPercent == nil)
        precondition(display(nil, refreshing: true).status == .loading)
        precondition(display(available, refreshing: true).remainingPercent == 60)
        let failed = display(exhausted, error: "test failure")
        precondition(failed.status == .failed && failed.remainingPercent == nil && failed.menuText == "!")
        precondition(exhausted.weekly?.remainingPercent == 0) // A read failure does not replace the snapshot.
        precondition(display(exhausted, at: now.addingTimeInterval(300)).status == .stale)
        let resetPassed = try snapshot(window(100), updatedAt: reset)
        precondition(display(resetPassed, at: reset).status == .stale)
        precondition(display(resetPassed, at: reset).remainingPercent == nil)
        let noReset = try snapshot(["usedPercent": 40, "windowDurationMins": 10_080])
        precondition(display(noReset).remainingPercent == 60 && display(noReset).reset == nil)
        precondition(dailyAverageRemaining(remaining: 60, resetsAt: noReset.weekly?.resetsAt) == nil)
        precondition(codexResetDescription(nil) == "Reset time unavailable")
        let utc = TimeZone(secondsFromGMT: 0)!
        precondition(codexResetDescription(reset, now: now, timeZone: utc) == "Resets Mon 18 JAN 08:00")
        precondition(codexResetDescription(reset, now: reset, timeZone: utc) == "Previous reset Mon 18 JAN 08:00")
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let localReset = ISO8601DateFormatter().date(from: "2026-10-17T03:30:00Z")!
        precondition(UsageDashboard.resetText(localReset, timeZone: sydney) == "Sat 17 OCT 14:30")
        precondition(UsageDashboard.resetText(localReset, timeZone: utc) == "Sat 17 OCT 03:30")
        let midnight = ISO8601DateFormatter().date(from: "2026-10-16T13:00:00Z")!
        precondition(UsageDashboard.resetText(midnight, timeZone: sydney) == "Sat 17 OCT 00:00")
        precondition(UsageDashboard.resetText(midnight, timeZone: utc) == "Fri 16 OCT 13:00")
        let low = try snapshot(window(99))
        precondition(display(low).status == .available && display(low).remainingPercent == 1)
        precondition(dailyAverageRemaining(remaining: 1, resetsAt: reset, now: now) == 0)
        for (primary, secondary) in [(window(80, minutes: 300), window(40)), (window(40), window(80, minutes: 300))] {
            let value = try UsageSnapshot(result: ["rateLimits": ["primary": primary, "secondary": secondary]], updatedAt: now)
            precondition(value.weekly?.remainingPercent == 60)
        }
        let mapped = try UsageSnapshot(result: [
            "rateLimits": ["primary": window(100)],
            "rateLimitsByLimitId": ["other": ["primary": window(100)], "codex": ["primary": window(40)]]
        ], updatedAt: now)
        precondition(mapped.weekly?.remainingPercent == 60)
        for missing in [[:], ["rateLimits": NSNull()],
                        ["rateLimits": ["limitId": "other", "primary": window(100)]],
                        ["rateLimitsByLimitId": ["other": ["primary": window(100)]]]] as [[String: Any]] {
            do { _ = try UsageSnapshot(result: missing); preconditionFailure("Expected invalid response") }
            catch CodexError.invalidResponse { }
        }

        // Exercise a real pipe/process timeout, stale partial bytes, sanitized error and recovery.
        // The fixture is local and never starts Codex or reads any account data.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-bar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.sh")
        try "#!/bin/sh\nprintf '{\"id\":'\nwhile IFS= read -r line; do :; done\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let client = CodexAppServerClient(requestTimeout: 0.5, executable: fixture)
        defer { client.stop() }
        func fetch() -> Result<UsageSnapshot, Error> {
            let done = DispatchSemaphore(value: 0)
            var result: Result<UsageSnapshot, Error>?
            client.fetchUsage { result = $0; done.signal() }
            precondition(done.wait(timeout: .now() + 5) == .success, "Client callback did not finish")
            return result!
        }
        guard case .failure(let timeout) = fetch(), case CodexError.requestTimedOut = timeout else {
            preconditionFailure("Expected timeout")
        }
        let script = #"""
        #!/bin/sh
        failed=0
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *'rateLimits'*)
              if [ "$failed" = 0 ]; then
                printf '{"id":%s,"error":{"code":401,"message":"unauthorized test-private-marker"}}\n' "$id"
                failed=1
              else
                printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080}}}}\n' "$id"
              fi ;;
          esac
        done
        """#
        try script.write(to: fixture, atomically: false, encoding: .utf8)
        guard case .failure(let failure) = fetch() else { preconditionFailure("Expected read error") }
        precondition(!failure.localizedDescription.contains("test-private-marker"))
        guard case CodexError.authenticationRequired = failure else {
            preconditionFailure("Expected sign-in diagnosis: \(failure.localizedDescription)")
        }
        let recovered = try fetch().get()
        precondition(recovered.weekly?.remainingPercent == 0)
        precondition(display(recovered, at: recovered.updatedAt).status == .exhausted)
        print("OK Codex: zero/nonzero, loading/error/unavailable/stale, correct weekly pool, reset labels, timeout and retry")
    }
}
