import SwiftUI
import KadriCore

/// Template silhouettes from the licensed source catalog, with separate real drive profiles.
enum PhotoToolSymbol {
    enum Profile: String, CaseIterable {
        case slotted, phillips, torx, hex

        var assetName: String { "profile-\(rawValue)" }
        var title: String {
            switch self {
            case .slotted: "ბრტყელი"
            case .phillips: "ჯვარედინი"
            case .torx: "Torx"
            case .hex: "ექვსკუთხა"
            }
        }
    }

    enum Hardware: String, CaseIterable {
        case nut, screw, bolt
        var assetName: String { "hardware-\(rawValue)" }
        var title: String {
            switch self {
            case .nut: "ქანჩი"
            case .screw: "ხრახნი"
            case .bolt: "ჭანჭიკი"
            }
        }
    }

    /// These catalog entries have a neutral toolbox placeholder, not a tool depiction.
    static let genericToolIDs: Set<String> = [
        "wire_cutter", "crimper_rj45", "voltage_tester", "antistatic_strap",
        "thermal_paste", "cable_ties", "spudger"
    ]

    static func assetName(for id: String) -> String? {
        guard ToolCatalog.name(id) != nil else { return nil }
        return "tool-symbol-\(id)"
    }

    static func profile(for id: String) -> Profile? {
        switch id {
        case "ph1", "ph2": .phillips
        case "flat_small", "flat_large": .slotted
        case "torx_t10", "torx_t20": .torx
        case "hex_key": .hex
        default: nil
        }
    }
}

struct PhotoToolSymbolView: View {
    let toolID: String
    var showsProfile = true

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            Group {
                if let asset = PhotoToolSymbol.assetName(for: toolID) {
                    Image(asset).renderingMode(toolID == "multimeter" ? .original : .template)
                        .resizable().scaledToFit()
                } else {
                    Image(systemName: "questionmark.square.dashed").resizable().scaledToFit()
                }
            }
            .foregroundStyle(Theme.Colors.brand[500]!)
            .padding(size * 0.12)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(alignment: .bottomTrailing) {
                if showsProfile, let profile = PhotoToolSymbol.profile(for: toolID) {
                    PhotoToolProfileView(profile: profile)
                        .frame(width: size * 0.43, height: size * 0.43)
                        .background(.white, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.Colors.brand[100]!, lineWidth: 1))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct PhotoToolProfileView: View {
    let profile: PhotoToolSymbol.Profile

    var body: some View {
        Image(profile.assetName).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(Theme.Colors.brand[600]!)
            .padding(5)
            .accessibilityLabel(profile.title)
    }
}
