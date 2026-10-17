import SwiftUI
import PhotosUI

/// The model's request for another photo: what to shoot and why, with the ways to provide it.
struct PhotoRequestCard: View {
    let round: Int
    let prompt: String
    let reason: String
    var cameraAvailable = true
    var camera: () -> Void
    var picked: Binding<PhotosPickerItem?>?
    var demo: (() -> Void)?
    var back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ფოტო \(round)")
                        .font(.kadri(13, weight: .semibold)).foregroundStyle(Theme.Colors.brand[600]!)
                    Text(prompt).font(.kadri(21, weight: .semibold)).tracking(-0.3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).padding(.top, 10)
                    Text(reason).font(.kadri(14.5)).lineSpacing(4)
                        .foregroundStyle(Theme.Colors.ink[600]!)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 8) {
                Button(action: camera) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera").font(.system(size: 16))
                        Text("გადაღება")
                    }
                }
                .buttonStyle(SessionButtonStyle(primary: true))
                .shadow(Theme.Shadow.pop)
                .disabled(!cameraAvailable)
                HStack(spacing: 8) {
                    if let picked {
                        PhotosPicker(selection: picked, matching: .images) { Text("გალერეიდან") }
                            .buttonStyle(SessionButtonStyle(primary: false))
                    }
                    #if DEBUG && targetEnvironment(simulator)
                    if let demo {
                        Button("სატესტო ფოტო", action: demo).buttonStyle(SessionButtonStyle(primary: false))
                    }
                    #endif
                    Button(action: back) { Text("უკან").padding(.horizontal, 2) }
                        .buttonStyle(SessionButtonStyle(primary: false)).fixedSize(horizontal: true, vertical: false)
                        .accessibilityHint("ნაბიჯებს დაუბრუნდება")
                }
            }.padding(.top, 16)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(16)
    }
}
