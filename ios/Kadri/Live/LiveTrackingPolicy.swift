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

/// Only actual depth/raycast evidence can pass. Feature-point and fixed-distance
/// debug fallbacks both have zero surface confidence in PartAnchors.
struct LivePlacementReport: Equatable {
    var parts = 0
    var accepted = 0
    var noDepth = 0
    var weakDepth = 0
    var invalidBox = 0
    var noPlacement = 0

    static func make(parts: [Part], placements: [PartPlacement]) -> Self {
        var result = Self(parts: parts.count)
        for part in parts {
            guard part.hasValidBox else { result.invalidBox += 1; continue }
            guard let placement = placements.first(where: { $0.id == part.id }) else {
                result.noPlacement += 1; continue
            }
            if LiveTrackingPolicy.supportedPlacement(placement) { result.accepted += 1 }
            else if !placement.confidence.isFinite || placement.confidence <= 0 { result.noDepth += 1 }
            else { result.weakDepth += 1 }
        }
        return result
    }
}

/// Retry local raycasts for a bounded window; never repeat the paid parts request.
struct LivePlacementRetry {
    private(set) var startedAt: TimeInterval?
    private(set) var lastAttempt: TimeInterval?
    private(set) var attempts = 0
    var duration: TimeInterval = 12
    var interval: TimeInterval = 1

    mutating func begin(now: TimeInterval) { startedAt = now; lastAttempt = nil; attempts = 0 }
    func expired(now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= duration
    }
    func shouldAttempt(now: TimeInterval) -> Bool {
        guard let startedAt, now >= startedAt, !expired(now: now) else { return false }
        return lastAttempt.map { now - $0 >= interval } ?? true
    }
    mutating func didAttempt(now: TimeInterval) { lastAttempt = now; attempts += 1 }
}

enum LiveRecoveryReason: String {
    case paused, trackingLost, staleFrame, missingFrame, viewChanged

    var text: String {
        switch self {
        case .paused: "კამერა შეჩერდა — სცადე ხელახლა ამოცნობა"
        case .trackingLost: "კამერის ტრეკინგი დაიკარგა — გააჩერე და სცადე ხელახლა"
        case .staleFrame: "კამერის კადრი აღარ ახლდება — სცადე ხელახლა ამოცნობა"
        case .missingFrame: "კამერის კადრი დაიკარგა — სცადე ხელახლა ამოცნობა"
        case .viewChanged: "ხედი მნიშვნელოვნად შეიცვალა — სცადე ხელახლა ამოცნობა"
        }
    }
}

enum LiveCameraStatus: Equatable {
    case unavailable, permission, steady, recognizing, tracked(Int), lookAgain, failed(String)
    case findingSurface, surfaceUnavailable, outOfView, recovery(LiveRecoveryReason)

    static func resolve(supported: Bool, permissionDenied: Bool, needsRecognition: Bool,
                        waitingForKeyframe: Bool, phase: SessionPhase, visibleCount: Int,
                        recovery: LiveRecoveryReason? = nil, findingSurface: Bool = false,
                        placedCount: Int = 0) -> Self {
        guard supported else { return .unavailable }
        if permissionDenied { return .permission }
        if needsRecognition { return recovery.map(Self.recovery) ?? .lookAgain }
        if case .error(let error, _) = phase { return .failed(error.localizedDescription) }
        if case .scanning = phase { return .recognizing }
        if waitingForKeyframe { return .steady }
        if visibleCount > 0 { return .tracked(visibleCount) }
        if findingSurface { return .findingSurface }
        if placedCount > 0 { return .outOfView }
        if case .parts = phase { return .surfaceUnavailable }
        return .lookAgain
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
        case .findingSurface: "ნაწილები ამოცნობილია — ზედაპირს ვეძებ. ნელა გადაადგილე კამერა."
        case .surfaceUnavailable: "ნაწილები ამოცნობილია, მაგრამ ზედაპირზე ვერ მივაბი. სცადე სხვა კუთხე."
        case .outOfView: "მონიშნული ნაწილები კადრში დააბრუნე"
        case .recovery(let reason): reason.text
        }
    }
}
