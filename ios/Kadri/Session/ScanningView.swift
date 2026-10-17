import SwiftUI

struct ScanningView: View {
    let startedAt: Date
    var cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 20) {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
                    Rectangle()
                        .fill(Theme.Colors.brand[400]!)
                        .frame(height: 2)
                        .shadow(color: Theme.Colors.brand[500]!.opacity(0.5), radius: 8)
                        .offset(y: reduceMotion ? proxy.size.height / 2 : (sweep ? proxy.size.height - 2 : 0))
                }
                .clipped()
                .animation(reduceMotion ? nil : .easeInOut(duration: 3.5).repeatForever(autoreverses: true), value: sweep)
            }
            .frame(height: 230)
            .accessibilityHidden(true)
            VStack(spacing: 12) {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(SessionPresentation.scanStatus(elapsed: context.date.timeIntervalSince(startedAt)))
                        .font(.kadri(18, weight: .semibold))
                }
                Text("კამერა ობიექტისკენ გეჭიროს")
                    .font(.kadri(14))
                    .foregroundStyle(Theme.Colors.ink[600]!)
                Button("გაუქმება", action: cancel)
                    .buttonStyle(SessionButtonStyle(primary: false))
                    .accessibilityLabel("გაუქმება")
                    .accessibilityHint("შეწყვეტს სკანირებას და აღწერაზე დაბრუნდება")
            }
            .padding(16)
            .glass()
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(.horizontal, 24)
        .onAppear { sweep = true }
    }
}
