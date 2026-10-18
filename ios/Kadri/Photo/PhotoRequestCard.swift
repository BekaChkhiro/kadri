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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// General framing advice: the request names the part, but nothing on the wire says how to frame it.
    private static let checklist = [("ცენტრში", "scope"), ("20–30 სმ", "ruler"), ("კარგი შუქი", "sun.max")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        if prompt.count <= 40 { illustration }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 4) {
                                Image(systemName: "camera").font(.system(size: 14)).accessibilityHidden(true)
                                Text("ფოტო \(round)").font(.kadri(12, weight: .semibold))
                            }
                            .foregroundStyle(Theme.Colors.brand[700]!)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Theme.Colors.brand[50]!, in: Capsule())
                            Text(prompt).font(.kadri(20, weight: .semibold)).tracking(-0.3).lineSpacing(2)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader).padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !reason.isEmpty {
                        Text(reason).font(.kadri(14.5)).lineSpacing(4)
                            .foregroundStyle(Theme.Colors.ink[600]!)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, prompt.count > 40 ? 8 : 12)
                    }
                    // Short chips on one wrapping row keep the checklist readable and close to the reason.
                    PhotoToolsLayout {
                        ForEach(Self.checklist, id: \.0) { text, symbol in
                            Label {
                                Text(text).font(.kadri(12, weight: .semibold)).lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            } icon: {
                                Image(systemName: symbol).font(.system(size: 14))
                                    .foregroundStyle(Theme.Colors.brand[600]!).accessibilityHidden(true)
                            }
                            .labelStyle(PhotoChipLabelStyle())
                            .foregroundStyle(Theme.Colors.ink[700]!)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.white, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.Colors.ink[200]!, lineWidth: 1))
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, prompt.count > 40 ? 8 : 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, prompt.count > 40 ? 0 : 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
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
                        PhotosPicker(selection: picked, matching: .images) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle").font(.system(size: 16))
                                Text("გალერეიდან")
                            }
                        }
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
            }.padding(.top, prompt.count > 40 ? 8 : 16).padding(.horizontal, 16)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(.vertical, prompt.count > 40 ? 12 : 16)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.45).delay(0.1)) { appeared = true }
        }
    }

    @ViewBuilder private var illustration: some View {
        if let image = UIImage(named: "illo-another-angle") {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 104, height: 104)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .shadow(Theme.Shadow.card)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
                .accessibilityHidden(true)
        }
    }
}

/// Icon and title side by side with the tool chips' spacing.
private struct PhotoChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}
