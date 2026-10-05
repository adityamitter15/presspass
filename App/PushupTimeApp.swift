import SwiftUI

@main
struct PressPassApp: App {
    @StateObject private var history = WorkoutHistoryStore()

    init() {
        #if DEBUG
        if let balance = AppEnvironment.current.demoBalance {
            SharedStore.earnedBalanceMinutes = balance
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(history)
                .preferredColorScheme(.dark)
                .tint(Theme.volt)
        }
    }
}

/// Home is the root; the workout opens over it as a full-screen cover and
/// settings as a sheet.
struct RootView: View {
    var body: some View {
        NavigationStack {
            HomeView()
        }
        #if DEBUG
        .gateSpikePresenter()
        #endif
    }
}
