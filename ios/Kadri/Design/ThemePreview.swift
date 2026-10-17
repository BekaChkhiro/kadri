import SwiftUI

/// Every token on one screen: palettes, type samples and a glass card.
struct ThemePreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                palette("brand", Theme.Colors.brand)
                palette("ink", Theme.Colors.ink)

                VStack(alignment: .leading, spacing: 6) {
                    Text("ნაბიჯი 1: მოხსენი ქანჩი").font(.kadri(21, weight: .semibold))
                    Text("ნაბიჯი 1: მოხსენი ქანჩი").font(.kadri(17, weight: .medium))
                    Text("ნაბიჯი 1: მოხსენი ქანჩი").font(.kadri(15))
                    Text("Inter 600 — Step 1: loosen the nut").font(.kadri(15, weight: .semibold))
                }
                .foregroundStyle(Theme.Colors.ink[900]!)

                ZStack {
                    LinearGradient(
                        colors: [Theme.Colors.brand[400]!, Theme.Colors.ink[700]!],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ნაბიჯი 1 / 4")
                            .font(.kadri(13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.brand[600]!)
                        Text("მოხსენი ქანჩი")
                            .font(.kadri(21, weight: .semibold))
                            .foregroundStyle(Theme.Colors.ink[900]!)
                        Text("სიფონის ქვედა ქანჩი საათის ისრის საწინააღმდეგოდ მოატრიალე.")
                            .font(.kadri(14.5))
                            .foregroundStyle(Theme.Colors.ink[600]!)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass()
                    .padding(16)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .padding(20)
        }
        .background(Theme.Colors.surface.ignoresSafeArea())
    }

    private func palette(_ name: String, _ colors: [Int: Color]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.kadri(13, weight: .semibold)).foregroundStyle(Theme.Colors.ink[500]!)
            HStack(spacing: 4) {
                ForEach(Theme.Colors.shades, id: \.self) { shade in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colors[shade]!)
                        .frame(height: 36)
                        .overlay(alignment: .bottom) {
                            Text("\(shade)")
                                .font(.kadri(8, weight: .medium))
                                .foregroundStyle(shade >= 500 ? .white : Theme.Colors.ink[800]!)
                                .padding(.bottom, 2)
                        }
                }
            }
        }
    }
}

#Preview {
    ThemePreview()
}
