import Foundation

/// The fixed tool catalog shared with the worker (`StepToolCard.id`) and the app's assets.
public enum ToolCatalog {
    private static let entries: [(id: String, name: String)] = [
        ("ph1", "ჯვარედინი სახრახნისი PH1"),
        ("ph2", "ჯვარედინი სახრახნისი PH2"),
        ("flat_small", "ბრტყელი სახრახნისი (პატარა)"),
        ("flat_large", "ბრტყელი სახრახნისი (დიდი)"),
        ("torx_t10", "Torx სახრახნისი T10"),
        ("torx_t20", "Torx სახრახნისი T20"),
        ("hex_key", "ექვსკუთხა გასაღები"),
        ("adjustable_wrench", "რეგულირებადი გასაღები"),
        ("open_wrench", "ქანჩის გასაღები"),
        ("socket_wrench", "თავაკიანი გასაღები"),
        ("pipe_wrench", "მილის გასაღები"),
        ("pliers", "ბრტყელტუჩა"),
        ("needle_pliers", "წვრილტუჩა"),
        ("wire_cutter", "მავთულის საჭრელი"),
        ("wire_stripper", "კაბელის გამწმენდი"),
        ("crimper_rj45", "RJ45 კრიმპერი"),
        ("multimeter", "მულტიმეტრი"),
        ("voltage_tester", "ძაბვის ინდიკატორი"),
        ("flashlight", "ფანარი"),
        ("bucket", "ვედრო"),
        ("towel", "ტილო"),
        ("gloves", "ხელთათმანები"),
        ("antistatic_strap", "ანტისტატიკური სამაჯური"),
        ("thermal_paste", "თერმოპასტა"),
        ("cable_ties", "კაბელის სამაგრები"),
        ("tape_measure", "რულეტკა"),
        ("level", "თარაზო"),
        ("drill", "დრელი"),
        ("hammer", "ჩაქუჩი"),
        ("utility_knife", "საკანცელარიო დანა"),
        ("plumber_tape", "ფუმლენტა"),
        ("spudger", "პლასტმასის სპუჯერი"),
    ]

    /// Catalog ids in display order.
    public static let ids: [String] = entries.map(\.id)

    /// Catalog id → Georgian name.
    public static let names: [String: String] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.name) })

    public static func name(_ id: String) -> String? {
        names[id]
    }

    /// Image asset for the tool's illustration, e.g. `UIImage(named: ToolCatalog.assetName("ph2"))`.
    public static func assetName(_ id: String) -> String {
        "tool-\(id)"
    }
}
