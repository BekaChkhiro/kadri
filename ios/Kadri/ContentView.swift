import SwiftUI

struct ContentView: View {
    // Enables a reproducible simulator smoke check without camera hardware.
    @State private var path: [String] = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ar-debug") ? ["ar"] : []
        #else
        []
        #endif
    }()
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-multi-photo") {
            NavigationStack { PhotoFlowView(session: PhotoProblemUITestFixture.makeSession()) }
        } else if ProcessInfo.processInfo.arguments.contains("--problem-demo") {
            PhotoProblemFlowView(model: PhotoProblemDemo.model(), isDemo: true)
        } else if ProcessInfo.processInfo.arguments.contains("--tool-icon-demo") {
            PhotoDemoShowcaseView(startWithTools: true)
        } else if ProcessInfo.processInfo.arguments.contains("--arrow-overlay-demo") {
            PhotoDemoShowcaseView()
        } else {
            mainContent
        }
        #else
        mainContent
        #endif
    }

    private var mainContent: some View {
        NavigationStack(path: $path) {
            PhotoFlowView()
                .navigationDestination(for: String.self) { destination in
                    switch destination {
                    case "flow": SessionFlowView()
                    case "sam": SegmentationBenchView()
                    case "signin": SignInView()
                    default: ARDebugView()
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
