/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import CoreGraphics
import simd

/// `startMode` "auto": where the object is in the picture the object query sends, as the server's
/// `boxX`, `boxY`, `boxWidth`, `boxHeight`, in pixels of the upright picture from its top-left.
struct EdgeQueryBox: Equatable {
    static let widthShare: CGFloat = 0.8
    static let aspect: CGFloat = 4.0 / 3.0

    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The box the user fits the object into: landscape 4:3, 80 % of the view's width, centred.
    /// The view draws this rectangle and the session sends it, so both must take it from here.
    static func screenRect(viewport: CGSize) -> CGRect? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let width = viewport.width * widthShare
        let height = width / aspect
        return CGRect(x: (viewport.width - width) / 2, y: (viewport.height - height) / 2, width: width, height: height)
    }

    /// A rectangle on screen in the picture's pixels. The screen shows an aspect-filled crop of the
    /// picture, so it goes back through ARKit's display transform (normalised sensor image to
    /// normalised view) for the same viewport.
    init?(screenRect rect: CGRect, viewport: CGSize, displayTransform: CGAffineTransform,
          pictureWidth: Int = EdgeStartQuery.imageWidth, pictureHeight: Int = EdgeStartQuery.imageHeight) {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let toSensor = displayTransform.inverted()
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { CGPoint(x: $0.x / viewport.width, y: $0.y / viewport.height).applying(toSensor) }
        self.init(sensorCorners: corners, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
    }

    /// The model's box as a tracker pose places it in the tracker's image; nil when a corner is
    /// behind the camera.
    init?(trackerPose pose: [Float], boundsMin lo: SIMD3<Float>, boundsMax hi: SIMD3<Float>,
          intrinsics k: ScaledIntrinsics, imageWidth: Int, imageHeight: Int,
          pictureWidth: Int = EdgeStartQuery.imageWidth, pictureHeight: Int = EdgeStartQuery.imageHeight) {
        var corners: [CGPoint] = []
        for corner in 0..<8 {
            let p = PoseMath.transform(pose, corner & 1 == 0 ? lo.x : hi.x, corner & 2 == 0 ? lo.y : hi.y,
                                       corner & 4 == 0 ? lo.z : hi.z)
            guard p.z > 0.02 else { return nil }
            let u: Float = (k.fu * p.x / p.z + k.ppu) / Float(imageWidth)
            let v: Float = (k.fv * p.y / p.z + k.ppv) / Float(imageHeight)
            corners.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
        }
        self.init(sensorCorners: corners, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
    }

    /// Points in the landscape sensor image, normalised, turned upright as `EdgeStartQuery` turns
    /// the JPEG; the box around them, clamped to the picture.
    private init?(sensorCorners: [CGPoint], pictureWidth: Int, pictureHeight: Int) {
        let w = CGFloat(pictureWidth), h = CGFloat(pictureHeight)
        let upright = sensorCorners.map { CGPoint(x: (1 - $0.y) * w, y: $0.x * h) }
        guard let first = upright.first, upright.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var lo = first, hi = first
        for p in upright {
            lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        let left = Int(max(0, min(w, lo.x)).rounded()), top = Int(max(0, min(h, lo.y)).rounded())
        let right = Int(max(0, min(w, hi.x)).rounded()), bottom = Int(max(0, min(h, hi.y)).rounded())
        guard right - left >= 1, bottom - top >= 1 else { return nil }
        self.init(x: left, y: top, width: right - left, height: bottom - top)
    }
}
