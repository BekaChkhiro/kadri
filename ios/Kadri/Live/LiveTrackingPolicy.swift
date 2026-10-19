import Foundation
import simd
import KadriCore

/// Conservative visibility rules for the consumer camera. Debug fallbacks are never evidence.
enum LiveTrackingPolicy {
    static func freshKeyframe(timestamp: TimeInterval, previous: TimeInterval?, now: TimeInterval) -> Bool {
        timestamp != previous && now - timestamp >= 0 && now - timestamp < 0.5
    }

    static func supportedPlacement(_ placement: PartPlacement) -> Bool {
        placement.confidence.isFinite && placement.confidence >= 0.5
    }

    static func sameView(reference: simd_float4x4, current: simd_float4x4) -> Bool {
        let delta = reference.inverse * current
        let distance = simd_length(SIMD3(delta.columns.3.x, delta.columns.3.y, delta.columns.3.z))
        let cosine = (delta.columns.0.x + delta.columns.1.y + delta.columns.2.z - 1) / 2
        guard distance.isFinite, cosine.isFinite else { return false }
        // These are conservative view limits, not a claim of measured tracking accuracy.
        return distance <= 0.3 && acos(min(1, max(-1, cosine))) <= .pi / 4
    }

    static func visible(_ projections: [PartProjection], viewport: CGSize,
                        trackingNormal: Bool, frameAge: TimeInterval) -> [PartProjection] {
        guard trackingNormal, frameAge >= 0, frameAge < 0.5,
              viewport.width > 0, viewport.height > 0 else { return [] }
        let screen = CGRect(origin: .zero, size: viewport)
        return projections.filter {
            $0.center.x.isFinite && $0.center.y.isFinite && screen.contains($0.center)
                && $0.corners.count == 4
                && $0.corners.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
    }
}

enum LiveCameraStatus: Equatable {
    case unavailable, permission, steady, recognizing, tracked(Int), lookAgain, failed(String)

    static func resolve(supported: Bool, permissionDenied: Bool, needsRecognition: Bool,
                        waitingForKeyframe: Bool, phase: SessionPhase, visibleCount: Int) -> Self {
        guard supported else { return .unavailable }
        if permissionDenied { return .permission }
        if needsRecognition { return .lookAgain }
        if case .error(let error, _) = phase { return .failed(error.localizedDescription) }
        if case .scanning = phase { return .recognizing }
        if waitingForKeyframe { return .steady }
        return visibleCount > 0 ? .tracked(visibleCount) : .lookAgain
    }

    var text: String {
        switch self {
        case .unavailable: "ცოცხალი რეჟიმი ამ მოწყობილობაზე მიუწვდომელია"
        case .permission: "ცოცხალი რეჟიმისთვის კამერაზე წვდომა ჩართე პარამეტრებში."
        case .steady: "დაიჭირე სტაბილურად…"
        case .recognizing: "ვამოცნობ…"
        case .tracked(let count): "\(count) ნაწილი"
        case .lookAgain: "ნახე თავიდან — ხელახლა ამოცნობაა საჭირო"
        case .failed(let message): message
        }
    }
}
