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
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            WorkoutView()
                .tabItem {
                    Label("Workout", systemImage: "figure.strengthtraining.traditional")
                }

            SetupView()
                .tabItem {
                    Label("Setup", systemImage: "gearshape.fill")
                }
        }
        #if DEBUG
        .gateSpikePresenter()
        #endif
    }
}
