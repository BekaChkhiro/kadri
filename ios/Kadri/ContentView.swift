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
            ThemePreview()
                .toolbar {
                    NavigationLink("AR დებაგი", value: "ar")
                    NavigationLink("SAM bench", value: "sam")
                }
                .navigationDestination(for: String.self) { destination in
                    if destination == "sam" {
                        SegmentationBenchView()
                    } else {
                        ARDebugView()
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
