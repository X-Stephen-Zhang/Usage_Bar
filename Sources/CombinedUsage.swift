import Foundation
import SwiftUI

func combinedStatusTitle(codex: UsageSnapshot?, claude: ClaudeUsageSnapshot?) -> String {
    func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
    return "X \(percent(codex?.weekly?.remainingPercent)) A "
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

    var body: some View {
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
            card(name: "Codex", plan: codex?.planLabel, color: .blue, note: nil, error: codexError) {
                quota(label: "Weekly", remaining: codex?.weekly?.remainingPercent,
                      reset: codex?.weekly?.resetsAt, color: .blue)
                daily(remaining: codex?.weekly?.remainingPercent, reset: codex?.weekly?.resetsAt)
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
        name: String, plan: String?, color: Color, note: String?, error: String?,
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

    private func ring(_ value: Int?, color: Color, size: CGFloat, lineWidth: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            if let value {
                Circle().trim(from: 0, to: min(Double(value), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
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
            detail: reset.map { "\($0.formatted(Self.dayStyle)) \($0.formatted(Self.timeStyle))" }
                ?? (remaining == nil ? "Waiting for data" : "Window reset")
        )
        .help(reset.map { "Resets \($0.formatted(Self.dayStyle)) \($0.formatted(Self.timeStyle))" } ?? "")
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
