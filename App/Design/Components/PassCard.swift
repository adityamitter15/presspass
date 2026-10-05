import PushupCore
import SwiftUI

/// A finished set, drawn as a ticket: "PRESS PASS" above the perforation with
/// the rep count, "ADMIT" and the minutes earned below it.
struct PassCard: View {
    enum Style {
        /// About 132 points high, for lists.
        case compact
        /// The summary version.
        case full
    }

    let record: WorkoutSessionRecord
    var style: Style = .full
    /// Used only to say "Today" and "Yesterday"; injectable for previews.
    var now: Date = .now

    private let perforation: CGFloat = 0.68
    private let notch: CGFloat = 13

    private var height: CGFloat { style == .compact ? 132 : 470 }

    var body: some View {
        ZStack {
            TicketShape(notchRadius: notch, perforation: perforation)
                .fill(Theme.ink700)
            TicketShape(notchRadius: notch, perforation: perforation)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.07), .white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            if style == .full {
                RadialGradient(
                    colors: [Theme.volt.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.5, y: 0.32),
                    startRadius: 0,
                    endRadius: 190
                )
                .clipShape(TicketShape(notchRadius: notch, perforation: perforation))
                .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                upper.frame(height: height * perforation)
                lower.frame(maxHeight: .infinity)
            }
            PerforationLine(notchRadius: notch, perforation: perforation)
                .stroke(Theme.textTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            TicketShape(notchRadius: notch, perforation: perforation)
                .stroke(Theme.line, lineWidth: 1)
        }
        .frame(height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(style == .full ? 0.5 : 0), radius: 24, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Above the perforation

    @ViewBuilder
    private var upper: some View {
        switch style {
        case .compact:
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Press pass").ticketText()
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text("\(record.reps)")
                            .font(Theme.heroNumeral(size: 50))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("press-ups")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.m)
                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    Text(PassFormat.day(record.startedAt, now: now)).ticketText(Theme.textPrimary)
                    Text(PassFormat.time(record.startedAt)).ticketText()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.s)
        case .full:
            VStack(spacing: 0) {
                HStack {
                    Text("Press pass").ticketText()
                    Spacer()
                    Text(PassFormat.serial(record.id)).ticketText(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                Text("\(record.reps)")
                    .font(Theme.heroNumeral(size: 150))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("press-ups")
                    .font(Theme.title(.title2))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)
        }
    }

    // MARK: Below the perforation

    @ViewBuilder
    private var lower: some View {
        switch style {
        case .compact:
            HStack(spacing: Theme.Space.m) {
                Text("Admit").ticketText()
                Text("\(record.minutesEarned) min")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.volt)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Barcode(seed: record.id)
                    .frame(width: 92, height: 18)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xs)
        case .full:
            VStack(spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Admit").ticketText()
                    Spacer()
                    Text("\(record.minutesEarned) \(record.minutesEarned == 1 ? "minute" : "minutes")")
                        .font(Theme.title(.title3))
                        .foregroundStyle(Theme.volt)
                }
                HStack(alignment: .top) {
                    detail("Date", PassFormat.day(record.startedAt, now: now))
                    Spacer()
                    detail("Time", PassFormat.time(record.startedAt))
                    Spacer()
                    detail("Duration", PassFormat.duration(record.durationSeconds))
                }
                Barcode(seed: record.id)
                    .frame(height: 26)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).ticketText(Theme.textTertiary)
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var accessibilityLabel: String {
        let day = PassFormat.day(record.startedAt, now: now)
        return "Press pass, \(record.reps) press-ups, \(record.minutesEarned) minutes earned, "
            + "\(day) at \(PassFormat.time(record.startedAt)), duration \(PassFormat.duration(record.durationSeconds))"
    }
}

// MARK: - Barcode

/// A decorative barcode. Bar widths come from the record id, so the same pass
/// always draws the same strip.
struct Barcode: View {
    let seed: UUID

    var body: some View {
        Canvas { context, size in
            var generator = SplitMix64(seed: seed)
            var x: CGFloat = 0
            var isBar = true
            while x < size.width {
                let unit = CGFloat(generator.next() % 3) + 1
                let width = isBar ? unit * 1.5 : unit
                if isBar {
                    let rect = CGRect(x: x, y: 0, width: min(width, size.width - x), height: size.height)
                    context.fill(Path(rect), with: .color(Theme.textSecondary.opacity(0.85)))
                }
                x += width
                isBar.toggle()
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small deterministic generator seeded from a UUID.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UUID) {
        let bytes = seed.uuid
        let high = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
        let low = [bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15]
        func fold(_ values: [UInt8]) -> UInt64 { values.reduce(0) { $0 << 8 | UInt64($1) } }
        state = fold(high) ^ fold(low).rotatedLeft(by: 17)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension UInt64 {
    func rotatedLeft(by count: UInt64) -> UInt64 {
        (self << count) | (self >> (64 - count))
    }
}

// MARK: - Formatting

/// One format for the day and time on both pass variants: upper case, so
/// "TODAY" and "1:14 AM" read the same in a list and on the summary.
enum PassFormat {
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "YESTERDAY" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened).uppercased()
    }

    /// m:ss
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A short ticket number from the record id.
    static func serial(_ id: UUID) -> String {
        "No. " + String(id.uuidString.prefix(6))
    }
}

#Preview {
    VStack(spacing: 24) {
        PassCard(
            record: WorkoutSessionRecord(
                startedAt: .now, durationSeconds: 52, reps: 12,
                repTimes: [2, 4, 6], shallowAttempts: 0, minutesEarned: 12
            ),
            style: .compact
        )
        PassCard(
            record: WorkoutSessionRecord(
                startedAt: .now, durationSeconds: 52, reps: 12,
                repTimes: [2, 4, 6], shallowAttempts: 0, minutesEarned: 12
            )
        )
    }
    .padding()
    .screenBackground()
}
