#if DEBUG
import Combine
import SwiftUI
import UIKit

/// DEBUG-only screen for the per-open gate feasibility spike
/// (`docs/gate-spike.md`): shows the pass state, grants or clears a pass,
/// opens the guarded app's URL scheme, and lists the intent event log.
/// A feasibility test, not a feature.
struct GateSpikeView: View {
    /// Adds a Done button, for when the screen is presented as a sheet.
    var showsDoneButton = false

    @Environment(\.dismiss) private var dismiss

    @AppStorage("gateSpike.returnURL") private var returnURL = "instagram://"
    @AppStorage("gateSpike.passMinutes") private var passMinutes = 2

    @State private var events: [GateSpikeStore.Event] = []
    @State private var openResult: String?

    var body: some View {
        Form {
            passSection
            returnSection
            logSection
        }
        .navigationTitle("Gate spike")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    // MARK: - Pass

    private var passSection: some View {
        Section("Pass") {
            // Re-evaluated every second so the status flips when a pass runs out.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(passStatus(now: context.date))
                    .monospacedDigit()
            }

            Stepper("Pass length: \(passMinutes) min", value: $passMinutes, in: 1...30)

            Button("Grant pass and return") {
                grantAndReturn()
            }

            Button("Clear pass", role: .destructive) {
                GateSpikeStore.clearPass()
                openResult = nil
            }
        }
    }

    private func passStatus(now: Date) -> String {
        guard let expiry = GateSpikeStore.passExpiry, GateSpikeStore.hasValidPass(now: now) else {
            return "No valid pass"
        }
        return "Pass valid until \(Self.timeFormatter.string(from: expiry))"
    }

    // MARK: - Return URL

    private var returnSection: some View {
        Section {
            TextField("instagram://", text: $returnURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if let openResult {
                Text(openResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("URL scheme to return to")
        } footer: {
            Text("Opened by Grant pass and return.")
        }
    }

    private func grantAndReturn() {
        let text = returnURL.trimmingCharacters(in: .whitespacesAndNewlines)
        GateSpikeStore.grantPass(minutes: passMinutes, detail: "\(passMinutes) min, \(text)")
        reload()
        guard let url = URL(string: text), url.scheme != nil else {
            openResult = "Pass granted, but \"\(text)\" is not a valid URL."
            return
        }
        // No canOpenURL check: that would need LSApplicationQueriesSchemes.
        UIApplication.shared.open(url) { success in
            openResult = success ? "Opened \(text)." : "Could not open \(text)."
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Event log, newest first (\(events.count))") {
            if events.isEmpty {
                Text("No events yet").foregroundStyle(.secondary)
            }
            ForEach(events.reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.kind).font(.subheadline.bold())
                    HStack {
                        Text(Self.logTimeFormatter.string(from: event.time))
                            .monospacedDigit()
                        if !event.detail.isEmpty {
                            Text(event.detail)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reload() {
        events = GateSpikeStore.events()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// Presents `GateSpikeView` as a sheet when an intercepted open asks for it,
/// so the flow can be tested end to end. Checks on appear, on becoming
/// active and when the intent posts its request.
private struct GateSpikePresenter: ViewModifier {
    @State private var showGate = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showGate) {
                NavigationStack {
                    GateSpikeView(showsDoneButton: true)
                }
            }
            .onAppear(perform: presentIfRequested)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                presentIfRequested()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: GateSpikeStore.gateRequestedNotification)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                presentIfRequested()
            }
    }

    private func presentIfRequested() {
        if GateSpikeStore.consumeGateRequest() {
            showGate = true
        }
    }
}

extension View {
    /// DEBUG only: shows the gate spike screen when an intent requests it.
    func gateSpikePresenter() -> some View {
        modifier(GateSpikePresenter())
    }
}
#endif
