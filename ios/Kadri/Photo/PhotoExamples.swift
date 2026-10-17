import UIKit

/// Bundled photos for trying the flow without taking one; each starts the session with its description filled in.
enum PhotoExample: CaseIterable {
    case sinkTrap, washingMachine, carEngine, microscope

    var label: String {
        switch self {
        case .sinkTrap: "ნიჟარა ჟონავს"
        case .washingMachine: "სარეცხის ჩართვა"
        case .carEngine: "ზეთის შემოწმება"
        case .microscope: "მიკროსკოპი"
        }
    }

    var prefill: String {
        switch self {
        case .sinkTrap: "ნიჟარა ჟონავს"
        case .washingMachine: "როგორ ჩავრთო სარეცხი მანქანა"
        case .carEngine: "როგორ შევამოწმო ზეთი"
        case .microscope: "როგორ მოვამზადო მიკროსკოპი"
        }
    }

    var fileName: String {
        switch self {
        case .sinkTrap: "sink-trap"
        case .washingMachine: "washing-machine"
        case .carEngine: "car-engine"
        case .microscope: "microscope"
        }
    }

    func image() -> UIImage? {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "jpg") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
