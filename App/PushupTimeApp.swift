import SwiftUI

@main
struct PushupTimeApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

struct RootTabView: View {
    private enum Tab {
        case home, workout, setup
    }

    /// Launch arguments (DEBUG only) can open straight on the workout or its
    /// summary; otherwise the app opens on Home.
    @State private var selection: Tab = {
        switch AppEnvironment.current.initialScreen {
        case .workout, .summary: return .workout
        case .home, nil: return .home
        }
    }()

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(Tab.home)

            WorkoutView()
                .tabItem {
                    Label("Workout", systemImage: "figure.strengthtraining.traditional")
                }
                .tag(Tab.workout)

            SetupView()
                .tabItem {
                    Label("Setup", systemImage: "gearshape.fill")
                }
                .tag(Tab.setup)
        }
        #if DEBUG
        .gateSpikePresenter()
        #endif
    }
}
