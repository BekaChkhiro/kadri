#if DEBUG
import SwiftUI
import KadriCore

struct PhotoDemoShowcaseView: View {
    @State private var selection: Int

    init(startWithTools: Bool = false) {
        _selection = State(initialValue: startWithTools ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("ჩვენება", selection: $selection) {
                Text("მოძრაობები").tag(0)
                Text("ხელსაწყოები").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
            if selection == 0 { PhotoArrowDemoView() }
            else { PhotoToolIconDemoView() }
        }
        .background(Theme.Colors.surface).preferredColorScheme(.light)
    }
}

/// An offline gallery of the exact symbols and tool cards used by photo instructions.
struct PhotoToolIconDemoView: View {
    @State private var tab = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ხელსაწყოები").font(.kadri(26, weight: .semibold))
                Text("ახალი აიქონები და თავების პროფილები")
                    .font(.kadri(14)).foregroundStyle(Theme.Colors.ink[600]!)
                Picker("ხედი", selection: $tab) {
                    Text("კატალოგი").tag(0)
                    Text("ბარათები").tag(1)
                }.pickerStyle(.segmented)
                if tab == 0 {
                    PhotoToolProfileGallery()
                    Text("დეტალები").font(.kadri(17, weight: .semibold))
                    HStack(spacing: 12) {
                        ForEach(PhotoToolSymbol.Hardware.allCases, id: \.rawValue) { hardware in
                            VStack(spacing: 8) {
                                Image(hardware.assetName).renderingMode(.template).resizable().scaledToFit()
                                    .foregroundStyle(Theme.Colors.brand[500]!).frame(width: 48, height: 48)
                                Text(hardware.title).font(.kadri(14, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    Text("ხელსაწყოების კატალოგი").font(.kadri(17, weight: .semibold))
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                        ForEach(ToolCatalog.ids, id: \.self) { id in
                            VStack(spacing: 12) {
                                PhotoToolSymbolView(toolID: id).frame(width: 68, height: 68)
                                Text(ToolCatalog.name(id) ?? id).font(.kadri(12, weight: .medium))
                                    .multilineTextAlignment(.center).frame(minHeight: 42)
                                if PhotoToolSymbol.genericToolIDs.contains(id) {
                                    Text("საერთო სიმბოლო").font(.kadri(10)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity).padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                } else {
                    PhotoToolCardSamples()
                }
            }.padding(20)
        }
        .background(Theme.Colors.surface).preferredColorScheme(.light)
    }
}

struct PhotoToolProfileGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("თავის ფორმა").font(.kadri(17, weight: .semibold))
            HStack(alignment: .top, spacing: 8) {
                ForEach(PhotoToolSymbol.Profile.allCases, id: \.rawValue) { profile in
                    VStack(spacing: 8) {
                        PhotoToolProfileView(profile: profile).frame(width: 44, height: 44)
                        Text(profile.title).font(.kadri(11, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PhotoToolCardSamples: View {
    static let tools: [StepToolCard] = [
        .init(id: "torx_t10", size: "T10", why: "თავი სრულად უნდა ჩაჯდეს ხრახნში.", sizeSource: "seen"),
        .init(id: "ph2", size: "PH2", why: "ჯვარედინი თავი მჭიდროდ უნდა მოერგოს.",
              sizeSource: "typical", fitCheck: "თუ თავისუფლად მოძრაობს, სხვა ზომა შეამოწმე.", alternatives: ["PH1"]),
        .init(id: "hex_key", why: "ექვსკუთხა პროფილი ბოლომდე ჩასვი და მორგება შეამოწმე.", sizeSource: "unknown"),
        .init(id: "open_wrench", size: "10 მმ", why: "გასაღები ქანჩის გვერდებს მჭიდროდ უნდა მოერგოს.", sizeSource: "model")
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Self.tools, id: \.id) { tool in PhotoToolCard(tool: tool) }
        }
    }
}
#endif
