import Foundation
import SwiftUI

struct CodexUsagePresentation {
    enum Status { case loading, unavailable, available, exhausted, stale, failed }
    let status: Status
    let remainingPercent: Int?
    let reset: Date?

    init(snapshot: UsageSnapshot?, error: String?, refreshing: Bool, now: Date = Date()) {
        reset = snapshot?.weekly?.resetsAt
        if error != nil {
            status = .failed
        } else if let snapshot, let weekly = snapshot.weekly {
            // Polling runs every two minutes. Missed polls and passed resets need a fresh reading.
            if now.timeIntervalSince(snapshot.updatedAt) >= 300 || reset.map({ $0 <= now }) == true {
                status = .stale
            } else {
                status = weekly.remainingPercent == 0 ? .exhausted : .available
            }
        } else {
            status = refreshing ? .loading : .unavailable
        }
        remainingPercent = (status == .available || status == .exhausted)
            ? snapshot?.weekly?.remainingPercent : nil
    }

    var menuText: String {
        switch status {
        case .loading: return "…"
        case .failed: return "!"
        case .stale: return "?"
        case .unavailable: return "—"
        case .exhausted: return "0%!"
        case .available: return "\(remainingPercent!)%"
        }
    }

    var message: String {
        switch status {
        case .loading: return "Loading Codex usage…"
        case .failed: return "Unable to read current usage."
        case .stale: return "Usage data is out of date. Waiting for a fresh reading."
        case .unavailable: return "Weekly limit unavailable."
        case .exhausted: return "Weekly quota exhausted."
        case .available: return "Weekly quota remaining."
        }
    }
}

func codexResetDescription(_ reset: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
    guard let reset else { return "Reset time unavailable" }
    return "\(reset <= now ? "Previous reset" : "Resets") \(UsageDashboard.resetText(reset, timeZone: timeZone))"
}

func combinedStatusTitle(codex: UsageSnapshot?, claude: ClaudeUsageSnapshot?,
                         codexError: String? = nil, refreshing: Bool = false, now: Date = Date()) -> String {
    func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
    let display = CodexUsagePresentation(snapshot: codex, error: codexError, refreshing: refreshing, now: now)
    return "X \(display.menuText) A "
        + "\(percent(claude?.fiveHour?.remainingPercent))|\(percent(claude?.weekly?.remainingPercent))"
}

/// Remaining weekly quota spread evenly over the days left until reset (at least one day).
func dailyAverageRemaining(remaining: Int?, resetsAt: Date?, now: Date = Date()) -> Int? {
    guard let remaining, let resetsAt else { return nil }
    let days = max(resetsAt.timeIntervalSince(now) / 86_400, 1)
    return Int((Double(remaining) / days).rounded())
}

struct UsageDashboard: View {
    let codex: UsageSnapshot?
    let claude: ClaudeUsageSnapshot?
    let codexError: String?
    let claudeError: String?
    let refreshing: Bool
    var claudePlan: String?
    var claudeConnected = true
    var onConnectClaude: () -> Void = {}
    var pinned = false
    let onRefresh: () -> Void
    var onTogglePin: () -> Void = {}
    let onQuit: () -> Void

    private static let timeStyle = Date.FormatStyle(locale: Locale(identifier: "en_GB"))
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    private static let dayStyle = Date.FormatStyle(locale: Locale(identifier: "en_GB"))
        .weekday(.abbreviated).day().month(.abbreviated)

    /// Both providers use Claude's compact local-time layout, with an uppercase month.
    static func resetText(_ date: Date, timeZone: TimeZone = .current) -> String {
        var day = dayStyle
        var time = timeStyle
        day.timeZone = timeZone
        time.timeZone = timeZone
        let month = date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: timeZone)
            .month(.abbreviated))
        let dateText = date.formatted(day).replacingOccurrences(of: month, with: month.uppercased())
        return "\(dateText) \(date.formatted(time))"
    }

    var body: some View {
        let codexDisplay = CodexUsagePresentation(snapshot: codex, error: codexError, refreshing: refreshing)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(refreshing ? "Refreshing…"
                         : (codex?.updatedAt).map { "Remaining · updated \($0.formatted(Self.timeStyle))" } ?? "Remaining")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                iconButton("arrow.clockwise", help: "Refresh", action: onRefresh).disabled(refreshing)
                iconButton(pinned ? "pin.slash" : "pin", help: pinned ? "Unpin" : "Pin to Desktop",
                           action: onTogglePin)
                iconButton("power", help: "Quit", action: onQuit)
            }
            card(name: "Codex", plan: codex?.planLabel, color: .blue,
                 note: codex.map { "as of " + asOf($0.updatedAt) }, error: codexError,
                 status: codexDisplay.message
                    + ((codexDisplay.status == .failed || codexDisplay.status == .stale)
                       ? codex?.weekly.map { "\nLast known remaining: \($0.remainingPercent)%" } ?? "" : "")) {
                column(ring: ring(codexDisplay.remainingPercent, color: .blue, size: 66, lineWidth: 7, fontSize: 20,
                                  exhausted: codexDisplay.status == .exhausted),
                       label: "Weekly", detail: codexDisplay.remainingPercent != nil
                        ? codexDisplay.reset.map { Self.resetText($0) } ?? "Reset unavailable"
                        : (codexDisplay.status == .loading ? "Loading…" : "Unavailable"))
                    .help(codexResetDescription(codexDisplay.reset))
                daily(remaining: codexDisplay.remainingPercent,
                      reset: codexDisplay.remainingPercent == nil ? nil : codexDisplay.reset)
            }
            card(name: "Claude", plan: claudePlan, color: .orange,
                 note: claude.map { "as of " + asOf($0.updatedAt) }, error: claudeError) {
                if claudeConnected {
                    quota(label: "5-hour", remaining: claude?.fiveHour?.remainingPercent,
                          reset: claude?.fiveHour?.resetsAt, color: .orange)
                    quota(label: "Weekly", remaining: claude?.weekly?.remainingPercent,
                          reset: claude?.weekly?.resetsAt, color: .orange)
                    daily(remaining: claude?.weekly?.remainingPercent, reset: claude?.weekly?.resetsAt)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reads Claude Code's own usage data through its status line. "
                             + "No password or keychain access.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Connect Claude Code", action: onConnectClaude)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        // The pinned window supplies its own translucent background.
        .background(pinned ? Color.clear : Color(nsColor: .windowBackgroundColor))
    }

    private func asOf(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(Self.timeStyle)
            : "\(date.formatted(Self.dayStyle)) \(date.formatted(Self.timeStyle))"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func card<Content: View>(
        name: String, plan: String?, color: Color, note: String?, error: String?, status: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.system(size: 13, weight: .semibold))
                if let plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.15)))
                        .foregroundStyle(color)
                }
                Spacer()
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 0) { content() }
            if let status {
                Text(status).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func ring(_ value: Int?, color: Color, size: CGFloat, lineWidth: CGFloat, fontSize: CGFloat,
                      exhausted: Bool = false) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            if let value {
                Circle().trim(from: 0, to: min(Double(value), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if exhausted {
                Text("!")
                    .font(.system(size: fontSize * 1.6, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Quota exhausted")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(value.map(String.init) ?? "—")
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    if value != nil {
                        Text("%").font(.system(size: fontSize * 0.55, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }

    /// One equal-width column: ring, label, one detail line. Columns line up across cards.
    private func column<Ring: View>(ring: Ring, label: String, detail: String) -> some View {
        VStack(spacing: 6) {
            ring.frame(height: 66)
            Text(label).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 100)
        .accessibilityElement(children: .combine)
    }

    private func quota(label: String, remaining: Int?, reset: Date?, color: Color) -> some View {
        column(
            ring: ring(remaining, color: color, size: 66, lineWidth: 7, fontSize: 20),
            label: label,
            detail: reset.map { Self.resetText($0) }
                ?? (remaining == nil ? "Waiting for data" : "Window reset")
        )
        .help(reset.map { "Resets \(Self.resetText($0))" } ?? "")
    }

    private func daily(remaining: Int?, reset: Date?) -> some View {
        column(
            ring: ring(dailyAverageRemaining(remaining: remaining, resetsAt: reset),
                       color: .green, size: 46, lineWidth: 5, fontSize: 14),
            label: "Daily avg",
            detail: reset.map { String(format: "%.1f days left", max($0.timeIntervalSinceNow, 0) / 86_400) } ?? "—"
        )
    }
}
