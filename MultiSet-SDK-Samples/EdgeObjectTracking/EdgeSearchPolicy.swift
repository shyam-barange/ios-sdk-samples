/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation
import simd

/// `startMode` "auto": when the server is asked where the object is, and whether its answer is used.
/// Plain values in and out, so the host check can pin it without ARKit.
enum EdgeSearchPolicy {
    /// The SDK's object tracking default for `confidenceThreshold`.
    static let minServerConfidence = 0.3
    /// Fastest camera turn a picture is sent at, in rad/s (about 29°/s); faster ones come out blurred.
    static let maxTurnRate: Float = 0.5

    /// A missing confidence is accepted, as the SDK's object tracking does.
    static func accepts(confidence: Double?) -> Bool {
        (confidence ?? 1) >= minServerConfidence
    }

    /// Whether the centre of the model's box is in front of the camera and inside the picture.
    static func isInView(_ trackerPose: [Float], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>,
                         intrinsics k: ScaledIntrinsics, width: Int, height: Int) -> Bool {
        let centre = (boundsMin + boundsMax) / 2
        let p = PoseMath.transform(trackerPose, centre.x, centre.y, centre.z)
        guard p.z > 0.05 else { return false }
        let u = k.fu * p.x / p.z + k.ppu, v = k.fv * p.y / p.z + k.ppv
        return u >= 0 && u <= Float(width) && v >= 0 && v <= Float(height)
    }

    /// Whether two tracker poses are the same placement: within 3 cm or 10 % of the distance, and 15°.
    static func agrees(_ a: [Float], _ b: [Float]) -> Bool {
        let offset = simd_distance(SIMD3(a[3], a[7], a[11]), SIMD3(b[3], b[7], b[11]))
        guard offset <= max(0.03, 0.1 * PoseMath.distance(a)) else { return false }
        var trace: Float = 0
        for row in 0..<3 {
            for column in 0..<3 { trace += a[row * 4 + column] * b[row * 4 + column] }
        }
        return acos(min(1, max(-1, (trace - 1) / 2))) <= 15 * .pi / 180
    }

    /// How fast the camera turned between two poses, in rad/s.
    static func turnRate(from a: simd_float4x4, to b: simd_float4x4, seconds: Double) -> Float {
        guard seconds > 0 else { return 0 }
        let angle = simd_quatf(a.inverse * b).angle
        return min(angle, 2 * .pi - angle) / Float(seconds)
    }
}

/// When the next picture may go to the server, and whether the track needs one.
struct EdgeSearchSchedule {
    enum Answer {
        case found
        case notFound
        case failed
    }

    enum Need {
        case none
        case notTracking
        case lost
        case weak
    }

    static let interval: Double = 1.5
    static let retryAfterError: Double = 4
    /// How long the library may look for a lost object by itself before the server is asked again.
    static let afterLost: Double = 2
    /// A recovery must hold, on screen, this long before it ends a loss: the library can "find" a
    /// lost object at the screen's edge for a moment, over and over (device logs, 2026-11-17).
    static let recoveryHolds: Double = 1
    /// The EOT samples draw a track below this confidence as weak; the library calls it lost below 0.55.
    static let weakConfidence: Float = 0.75
    static let afterWeak: Double = 3
    /// After the server confirms a weak track, it is not asked about weakness again for this long.
    static let weakQuietAfterConfirm: Double = 10
    static let missesBeforeHint = 5

    private(set) var nextAt: Double = 0
    private(set) var misses = 0
    /// Not tracking, lost or off screen for longer than `afterLost`, or weak for longer than `afterWeak`.
    private(set) var need = Need.notTracking
    var needsServer: Bool { need != .none }
    /// Since when the track has been lost or off screen, through recoveries that did not hold.
    private var lostSince: Double?
    private var heldSince: Double?
    private var weakSince: Double?
    private var weakQuietUntil: Double = 0

    var isStruggling: Bool { misses >= Self.missesBeforeHint }

    /// Only a weak check sends a box around the track: one the loss clock doubts may be on something
    /// else, and its box would point the server there (device logs, 2026-11-17).
    var boxesTheTrack: Bool { need == .weak }

    func isDue(at now: Double) -> Bool { now >= nextAt }

    /// Called once per frame with the tracker's state.
    mutating func observe(tracking: Bool, lost: Bool, onScreen: Bool = true, confidence: Float, at now: Double) {
        if !tracking {
            lostSince = nil
            heldSince = nil
        } else if lost || !onScreen {
            lostSince = lostSince ?? now
            heldSince = nil
        } else if lostSince != nil {
            heldSince = heldSince ?? now
            if let heldSince, now - heldSince >= Self.recoveryHolds {
                lostSince = nil
                self.heldSince = nil
            }
        }
        let weak = tracking && !lost && confidence >= 0 && confidence < Self.weakConfidence && now >= weakQuietUntil
        weakSince = weak ? (weakSince ?? now) : nil
        let lostTooLong = lostSince.map { now - $0 >= Self.afterLost } ?? false
        let weakTooLong = weakSince.map { now - $0 >= Self.afterWeak } ?? false
        need = !tracking ? .notTracking : lostTooLong ? .lost : weakTooLong ? .weak : .none
    }

    mutating func sent(at now: Double) {
        nextAt = now + Self.interval
    }

    mutating func answered(_ answer: Answer, at now: Double) {
        switch answer {
        case .found: misses = 0
        case .notFound: misses += 1
        case .failed: nextAt = max(nextAt, now + Self.retryAfterError)
        }
    }

    /// A server pose started the tracker: the track is new, so its history goes.
    mutating func started() {
        lostSince = nil
        heldSince = nil
        weakSince = nil
        need = .none
    }

    /// The server's pose agreed with the track, so the track is kept.
    mutating func confirmed(at now: Double) {
        lostSince = nil
        heldSince = nil
        weakSince = nil
        weakQuietUntil = now + Self.weakQuietAfterConfirm
        need = .none
    }
}
