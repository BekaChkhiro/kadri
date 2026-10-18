import GoogleSignIn
import SwiftUI

@main
struct KadriApp: App {
    @State private var app = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .environment(app.googleAuth)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--arrow-overlay-demo") ||
                       ProcessInfo.processInfo.arguments.contains("--tool-icon-demo") ||
                       ProcessInfo.processInfo.arguments.contains("--problem-demo") { return }
                    #endif
                    Segmenter.preload(); await app.googleAuth.restorePreviousSignIn()
                }
        }
    }
}
