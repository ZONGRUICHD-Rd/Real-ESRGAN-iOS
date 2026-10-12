import SwiftUI

@main
struct RealESRGANApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            AppActivity.shared.setInBackground(phase == .background)
        }
    }
}
