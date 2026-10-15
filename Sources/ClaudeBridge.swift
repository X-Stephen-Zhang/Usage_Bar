import Foundation

struct ClaudeLimitWindow {
    let usedPercent: Double
    let resetsAt: Date?

    /// Parses one Claude Code status line window (`used_percentage`, `resets_at` in epoch seconds).
    /// A window whose reset time has passed is reported as fully available.
    init?(json: [String: Any]?, now: Date = Date()) {
        guard let json, let used = (json["used_percentage"] as? NSNumber)?.doubleValue,
              used.isFinite, (0...100).contains(used) else { return nil }
        let reset = (json["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if let reset, reset <= now {
            usedPercent = 0
            resetsAt = nil
        } else {
            usedPercent = used
            resetsAt = reset
        }
    }

    var remainingPercent: Int { Int((100 - usedPercent).rounded()) }
}

struct ClaudeUsageSnapshot {
    let fiveHour: ClaudeLimitWindow?
    let weekly: ClaudeLimitWindow?
    let updatedAt: Date

    init?(rateLimits: [String: Any], capturedAt: Date, now: Date = Date()) {
        fiveHour = ClaudeLimitWindow(json: rateLimits["five_hour"] as? [String: Any], now: now)
        weekly = ClaudeLimitWindow(json: rateLimits["seven_day"] as? [String: Any], now: now)
        updatedAt = capturedAt
        guard fiveHour != nil || weekly != nil else { return nil }
    }
}

/// Claude usage comes from Claude Code's own status line data: Claude Code runs
/// `UsageBar --statusline`, which saves `rate_limits` to a local file that the menu bar app reads.
/// No credentials, keychain access or network requests are involved.
enum ClaudeBridge {
    private static let fileManager = FileManager.default
    private static let supportDirectory = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Usage Bar", isDirectory: true)
    static let dataURL = supportDirectory.appendingPathComponent("claude-rate-limits.json")
    /// The user's own status line, kept so it still runs (chained) and can be restored on disconnect.
    private static let previousURL = supportDirectory.appendingPathComponent("previous-statusline.json")
    private static let settingsURL = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let marker = "--statusline"

    // MARK: Menu bar app side

    static func load(now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: dataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = json["rate_limits"] as? [String: Any],
              let captured = (json["captured_at"] as? NSNumber)?.doubleValue else { return nil }
        return ClaudeUsageSnapshot(rateLimits: rateLimits,
                                   capturedAt: Date(timeIntervalSince1970: captured), now: now)
    }

    static var isConnected: Bool {
        guard let command = (readSettings()["statusLine"] as? [String: Any])?["command"] as? String else {
            return false
        }
        return command.contains(marker) && command.contains("UsageBar")
    }

    static func connect() throws {
        var settings = readSettings()
        guard !isConnected else { return }
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        var statusLine: [String: Any] = ["type": "command"]
        if let previous = settings["statusLine"] as? [String: Any] {
            try JSONSerialization.data(withJSONObject: previous).write(to: previousURL, options: .atomic)
            statusLine = previous
            statusLine["type"] = "command"
        } else {
            try? fileManager.removeItem(at: previousURL)
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        statusLine["command"] = "\"\(executable)\" \(marker)"
        settings["statusLine"] = statusLine
        try writeSettings(settings)
    }

    static func disconnect() throws {
        guard isConnected else { return }
        var settings = readSettings()
        if let data = try? Data(contentsOf: previousURL),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? fileManager.removeItem(at: previousURL)
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Subscription label from the account profile Claude Code keeps in `~/.claude.json`,
    /// e.g. "Pro", "Max 5x", "Max 20x".
    static func planLabel() -> String? {
        let url = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let type = account["organizationType"] as? String, !type.isEmpty else { return nil }
        return planLabel(organizationType: type,
                         rateLimitTier: account["organizationRateLimitTier"] as? String)
    }

    static func planLabel(organizationType: String, rateLimitTier: String?) -> String {
        let name = organizationType.replacingOccurrences(of: "claude_", with: "")
        var label = name.prefix(1).uppercased() + name.dropFirst()
        if name == "max", let tier = rateLimitTier,
           let multiple = tier.range(of: #"\d+x"#, options: .regularExpression) {
            label += " " + tier[multiple]
        }
        return label
    }

    // MARK: Claude Code CLI `/usage` (auto refresh without using Claude Code)

    static func findCLI() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["CLAUDE_PATH"],
                          home + "/.local/bin/claude", home + "/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.npm-global/bin/claude"].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Runs `claude -p /usage` (a local command: no model call, no quota) and saves the result
    /// in the same file the status line writes. The CLI uses its own sign-in.
    static func refreshFromCLI(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let cli = findCLI() else {
                completion("Claude Code CLI not found. Install it, then run `claude auth login`.")
                return
            }
            try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let process = Process()
            let output = Pipe()
            process.executableURL = cli
            process.arguments = ["-p", "/usage", "--no-session-persistence",
                                 "--strict-mcp-config", "--setting-sources", ""]
            process.currentDirectoryURL = supportDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                completion("Could not run Claude Code: \(error.localizedDescription)")
                return
            }
            let timeout = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            let text = String(decoding: data, as: UTF8.self)
            let now = Date()
            guard let rateLimits = parseUsageOutput(text, now: now) else {
                completion(text.localizedCaseInsensitiveContains("log")
                    ? "Claude Code is not signed in. Run `claude auth login` in Terminal."
                    : "Could not read Claude Code /usage output.")
                return
            }
            let record: [String: Any] = ["rate_limits": rateLimits, "captured_at": now.timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                try? data.write(to: dataURL, options: .atomic)
            }
            completion(nil)
        }
    }

    /// Parses lines like
    /// `Current session: 67% used · resets Oct 14 at 2:50am (Australia/Sydney)` and
    /// `Current week (all models): 13% used · resets Oct 17 at 8pm (Australia/Sydney)`
    /// into the status line's `rate_limits` shape.
    static func parseUsageOutput(_ text: String, now: Date = Date()) -> [String: Any]? {
        func window(_ prefix: String) -> [String: Any]? {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: prefix)
                + #"[^:\n]*:\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets ([^(\n]+?)\s*(?:\(([^)]+)\))?)?\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let usedRange = Range(match.range(at: 1), in: text),
                  let used = Double(text[usedRange]) else { return nil }
            var result: [String: Any] = ["used_percentage": used]
            if let resetRange = Range(match.range(at: 2), in: text) {
                let zone = Range(match.range(at: 3), in: text).flatMap { TimeZone(identifier: String(text[$0])) }
                if let reset = parseResetDate(String(text[resetRange]), timeZone: zone ?? .current, now: now) {
                    result["resets_at"] = reset.timeIntervalSince1970
                }
            }
            return result
        }
        var rateLimits: [String: Any] = [:]
        rateLimits["five_hour"] = window("Current session")
        rateLimits["seven_day"] = window("Current week (all models)")
        return rateLimits.isEmpty ? nil : rateLimits
    }

    private static func parseResetDate(_ text: String, timeZone: TimeZone, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        // Missing fields (year, or the day for time-only text) come from today; minutes/seconds stay 0.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.defaultDate = calendar.startOfDay(for: now)
        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, h:mma", "MMM d, ha", "h:mma", "ha"] {
            formatter.dateFormat = format
            guard var date = formatter.date(from: text) else { continue }
            // The text has no year (or no day): move past `now` when it parsed into the past.
            let step: Calendar.Component = format.hasPrefix("MMM") ? .year : .day
            if date < now.addingTimeInterval(-3_600) {
                date = Calendar.current.date(byAdding: step, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }

    // MARK: Status line side (runs inside Claude Code; must stay fast)

    static func runStatusLine() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let rateLimits = json?["rate_limits"] as? [String: Any]

        // Sessions without rate limits (API keys, before the first reply) leave the last data in place.
        if let rateLimits, rateLimits["five_hour"] != nil || rateLimits["seven_day"] != nil {
            try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let record: [String: Any] = ["rate_limits": rateLimits,
                                         "captured_at": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                try? data.write(to: dataURL, options: .atomic)
            }
        }

        if let data = try? Data(contentsOf: previousURL),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let command = previous["command"] as? String, !command.contains(marker) {
            exit(runChained(command, input: input))
        }
        if let rateLimits, let snapshot = ClaudeUsageSnapshot(rateLimits: rateLimits, capturedAt: Date()) {
            func percent(_ window: ClaudeLimitWindow?) -> String { window.map { "\($0.remainingPercent)%" } ?? "—" }
            print("Claude left · 5h \(percent(snapshot.fiveHour)) · week \(percent(snapshot.weekly))")
        }
        exit(0)
    }

    private static func runChained(_ command: String, input: Data) -> Int32 {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        do {
            try process.run()
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }
}
