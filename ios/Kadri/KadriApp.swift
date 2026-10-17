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
                .task { await app.googleAuth.restorePreviousSignIn() }
        }
    }
}
