import PushupCore
import SwiftUI

/// Shown inside the workout cover after a set: the screen dims and the pass
/// "prints" up into place, with the average tempo, any shallow attempts and
/// the way out underneath.
struct WorkoutSummaryView: View {
    let record: WorkoutSessionRecord
    /// Whether apps are chosen, so earned minutes can be spent right away.
    let canUseMinutes: Bool
    let onUseMinutes: () -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var printed = false

    private var tempo: Double? { WorkoutStats.averageTempo(of: record) }

    var body: some View {
        ZStack {
            Theme.ink900
                .opacity(printed ? 0.9 : 0)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    PassCard(record: record, style: .full)
                        .frame(maxWidth: 360)
                        .offset(y: printed || reduceMotion ? 0 : 160)
                        .rotationEffect(.degrees(printed || reduceMotion ? 0 : -6), anchor: .bottom)
                        .opacity(printed ? 1 : 0)

                    details
                        .opacity(printed ? 1 : 0)
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.l)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .task {
            // One beat so the dim and the print are seen starting from nothing.
            try? await Task.sleep(for: .milliseconds(120))
            withMotion(.print) { printed = true }
        }
        .sensoryFeedback(.success, trigger: printed)
    }

    private var details: some View {
        VStack(spacing: Theme.Space.m) {
            if let tempo {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "metronome.fill")
                        .foregroundStyle(Theme.volt)
                        .accessibilityHidden(true)
                    Text("\(Int(tempo.rounded())) reps per minute on average")
                        .foregroundStyle(Theme.textPrimary)
                }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
            }
            if record.shallowAttempts > 0 {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundStyle(Theme.amber)
                        .accessibilityHidden(true)
                    Text(shallowText)
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .multilineTextAlignment(.leading)
            }
        }
    }

    private var shallowText: String {
        let n = record.shallowAttempts
        return "\(n) \(n == 1 ? "attempt" : "attempts") did not count: not low enough"
    }

    private var actions: some View {
        VStack(spacing: Theme.Space.m) {
            if canUseMinutes {
                GlassButton("Use my minutes", action: onUseMinutes)
            }
            PrimaryButton("Done", action: onDone)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.l)
        .opacity(printed ? 1 : 0)
        .motion(.smooth, value: printed)
    }
}
