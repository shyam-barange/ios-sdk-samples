/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import CoreGraphics
import Foundation
import simd

/// Sizes the guide from a measured depth, so the start outline is the size of the object under it.
/// Poses are the tracker's: row-major, model to camera, x right, y down, z forward.
enum GuideSizing {
    /// Where the guide's model origin falls in an image with these intrinsics; nil behind the camera.
    static func originPixel(guidePose pose: [Float], intrinsics k: ScaledIntrinsics) -> CGPoint? {
        let z = pose[11]
        guard z > 0.02 else { return nil }
        return CGPoint(x: CGFloat(k.fu * pose[3] / z + k.ppu), y: CGFloat(k.fv * pose[7] / z + k.ppv))
    }

    /// The camera-z of the model's nearest bounding-box corner, relative to its origin.
    static func frontOffset(guidePose pose: [Float], boundsMin lo: SIMD3<Float>, boundsMax hi: SIMD3<Float>) -> Float {
        var front = Float.greatestFiniteMagnitude
        for corner in 0..<8 {
            let c = SIMD3<Float>(corner & 1 == 0 ? lo.x : hi.x, corner & 2 == 0 ? lo.y : hi.y, corner & 4 == 0 ? lo.z : hi.z)
            front = min(front, pose[8] * c.x + pose[9] * c.y + pose[10] * c.z)
        }
        return front
    }

    /// The guide distance, along the origin's line of sight, that puts the model's front on a surface
    /// measured `surfaceDepth` metres away.
    static func distance(surfaceDepth: Float, guidePose pose: [Float], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) -> Float {
        let originZ = surfaceDepth - frontOffset(guidePose: pose, boundsMin: boundsMin, boundsMax: boundsMax)
        return originZ * PoseMath.distance(pose) / pose[11]
    }

    /// The median of the valid depths in the square window around a depth-map pixel; nil when fewer
    /// than half of the window's samples are valid.
    static func medianDepth(at x: Int, _ y: Int, radius: Int, width: Int, height: Int,
                            depth: (_ x: Int, _ y: Int) -> Float?) -> Float? {
        let xs = max(0, x - radius)...min(width - 1, x + radius)
        let ys = max(0, y - radius)...min(height - 1, y + radius)
        guard !xs.isEmpty, !ys.isEmpty else { return nil }
        var samples: [Float] = []
        for yy in ys {
            for xx in xs {
                if let d = depth(xx, yy), d.isFinite, d > 0 { samples.append(d) }
            }
        }
        guard samples.count * 2 >= xs.count * ys.count else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
