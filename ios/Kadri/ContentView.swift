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
        NavigationStack(path: $path) {
            PhotoFlowView()
                .toolbar {
                    Menu("დებაგი", systemImage: "ellipsis.circle") {
                        NavigationLink("სესია", value: "flow")
                        NavigationLink("AR დებაგი", value: "ar")
                        NavigationLink("SAM bench", value: "sam")
                        NavigationLink("შესვლა", value: "signin")
                    }
                }
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
