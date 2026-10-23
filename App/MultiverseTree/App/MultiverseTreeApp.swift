import SwiftUI
import MultiverseCore

@main
struct MultiverseTreeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Registration must happen before the app finishes launching.
        BackgroundResearch.register { AppModelRegistry.scheduler }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { AppModelRegistry.scheduler = model.scheduler }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundResearch.schedule() }
            if phase == .active { model.runQueue() }
        }
    }
}

/// Lets the BGTask handler reach the scheduler without capturing SwiftUI state.
enum AppModelRegistry {
    nonisolated(unsafe) static var scheduler: ResearchScheduler?
}
