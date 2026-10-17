import SwiftUI
import KadriCore

struct ContentView: View {
    var body: some View {
        ZStack {
            Color(red: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF5 / 255)
                .ignoresSafeArea()
            Text("გამარჯობა, კადრი")
                .font(.title2.weight(.semibold))
        }
    }
}

#Preview {
    ContentView()
}
