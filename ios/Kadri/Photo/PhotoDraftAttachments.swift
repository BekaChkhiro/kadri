import SwiftUI
import KadriCore

/// Photos stay in evidence order; the model chooses the instruction order after submission.
struct PhotoDraftAttachments: View {
    let photos: [ProblemPhoto]
    let selectedID: String?
    let canAdd: Bool
    let importing: Bool
    let select: (String) -> Void
    let remove: (String) -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        Button { select(photo.id) } label: {
                            if let image = UIImage(data: photo.image) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 52, height: 52).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedID == photo.id ? Theme.Colors.brand[500]! : .clear, lineWidth: 2))
                                    .overlay(alignment: .bottomLeading) {
                                        Text("\(index + 1)").font(.kadri(10, weight: .semibold)).foregroundStyle(.white)
                                            .padding(4).background(.black.opacity(0.55), in: Circle()).padding(3)
                                    }
                            }
                        }.buttonStyle(.plain)
                            .accessibilityLabel("ფოტო \(index + 1)")
                            .accessibilityIdentifier("capture.photo.\(index + 1)")
                            .accessibilityAddTraits(selectedID == photo.id ? .isSelected : [])
                    }
                }.padding(3)
            }
            VStack(alignment: .trailing, spacing: 7) {
                Button(action: add) {
                    Label(importing ? "იტვირთება…" : "ფოტოს დამატება", systemImage: "plus.circle.fill")
                        .font(.kadri(12, weight: .semibold))
                }.disabled(!canAdd).accessibilityIdentifier("capture.addPhoto")
                if photos.count > 1, let selectedID {
                    Button("არჩეულის წაშლა", role: .destructive) { remove(selectedID) }.font(.kadri(11))
                } else {
                    Text("\(photos.count)/5 ფოტო").font(.kadri(11)).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 16).padding(.top, 10)
    }
}
