/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import CoreGraphics
import Foundation

/// An outline in image pixels (x right, y down): line segments as consecutive point pairs, or dots.
enum OutlineShape: Equatable {
    case segments([CGPoint])
    case points([CGPoint])

    var isEmpty: Bool {
        switch self {
        case .segments(let points), .points(let points): return points.isEmpty
        }
    }
}

/// An object's model projected at a pose: the mesh's sharp edges as lines, or, for smooth or very
/// dense meshes, a thinned set of its vertices as dots.
final class ModelOutline {
    private static let maxTrianglesForEdges = 80_000
    private static let maxPoints = 3000

    /// x,y,z,x,y,z per edge in model coordinates; nil when dots are used.
    private let segments: [Float]?
    private let points: [Float]

    init(mesh: ObjMesh) {
        points = mesh.thinnedPoints(max: Self.maxPoints)
        var segments = mesh.triangles.count <= Self.maxTrianglesForEdges ? Self.sharpEdges(mesh) : nil
        // Too few lines say nothing about the shape; too many are a scribble.
        if let s = segments, s.count < 6 * 6 || s.count > 6 * 12_000 { segments = nil }
        self.segments = segments
    }

    convenience init(obj: URL) throws {
        self.init(mesh: try ObjMesh(url: obj))
    }

    var usesSegments: Bool { segments != nil }

    func shape(pose: [Float], intrinsics: ScaledIntrinsics) -> OutlineShape {
        func project(_ xyz: [Float], _ at: Int) -> CGPoint? {
            let c = PoseMath.transform(pose, xyz[at], xyz[at + 1], xyz[at + 2])
            if c.z <= 0.02 { return nil }
            return CGPoint(x: CGFloat(intrinsics.fu * c.x / c.z + intrinsics.ppu),
                           y: CGFloat(intrinsics.fv * c.y / c.z + intrinsics.ppv))
        }
        if let segments {
            var lines: [CGPoint] = []
            lines.reserveCapacity(segments.count / 3)
            for i in stride(from: 0, to: segments.count, by: 6) {
                if let a = project(segments, i), let b = project(segments, i + 3) { lines += [a, b] }
            }
            return .segments(lines)
        }
        var dots: [CGPoint] = []
        dots.reserveCapacity(points.count / 3)
        for i in stride(from: 0, to: points.count, by: 3) {
            if let p = project(points, i) { dots.append(p) }
        }
        return .points(dots)
    }

    /// Edges on the boundary or between faces that meet at more than about 20 degrees.
    private static func sharpEdges(_ mesh: ObjMesh) -> [Float] {
        let vertices = mesh.vertices
        // CAD exports often repeat a vertex for every face; merge by position first.
        func quantise(_ metres: Float) -> Int64 { (Int64((Double(metres) * 10_000).rounded()) + (1 << 20)) & 0x1FFFFF }
        var byPosition: [Int64: Int] = [:]
        var merged = [Int](repeating: 0, count: vertices.count)
        for (i, v) in vertices.enumerated() {
            let key = (quantise(v.x) << 42) | (quantise(v.y) << 21) | quantise(v.z)
            if let first = byPosition[key] {
                merged[i] = first
            } else {
                byPosition[key] = i
                merged[i] = i
            }
        }
        var firstNormal: [Int64: SIMD3<Float>] = [:]
        var sharp: [Int64: Bool] = [:]
        for (t0, t1, t2) in mesh.triangles {
            guard t0 < vertices.count, t1 < vertices.count, t2 < vertices.count else { continue }
            let a = merged[t0], b = merged[t1], c = merged[t2]
            if a == b || b == c || a == c { continue }
            let n = cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            let length = (n * n).sum().squareRoot()
            if length < 1e-12 { continue }
            let normal = n / length
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let key = (Int64(min(p, q)) << 32) | Int64(max(p, q))
                if let other = firstNormal[key] {
                    sharp[key] = (normal * other).sum() < 0.94
                } else {
                    firstNormal[key] = normal
                    sharp[key] = true
                }
            }
        }
        var segments: [Float] = []
        for (key, isSharp) in sharp where isSharp {
            let p = vertices[Int(key >> 32)], q = vertices[Int(key & 0xFFFF_FFFF)]
            segments += [p.x, p.y, p.z, q.x, q.y, q.z]
        }
        return segments
    }

    private static func cross(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    }
}

/// Maps tracker image pixels to view points through ARKit's display transform for the viewport.
struct OutlineViewMapper {
    let imageSize: CGSize
    let displayTransform: CGAffineTransform
    let viewportSize: CGSize

    init(imageSize: CGSize, displayTransform: CGAffineTransform, viewportSize: CGSize) {
        self.imageSize = imageSize
        self.displayTransform = displayTransform
        self.viewportSize = viewportSize
    }

    private var isUsable: Bool {
        imageSize.width > 0 && imageSize.height > 0 && viewportSize.width > 0 && viewportSize.height > 0
    }

    func map(_ point: CGPoint) -> CGPoint {
        let normalized = CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height).applying(displayTransform)
        return CGPoint(x: normalized.x * viewportSize.width, y: normalized.y * viewportSize.height)
    }

    func map(_ shape: OutlineShape) -> OutlineShape {
        switch shape {
        case .segments(let points): return .segments(isUsable ? points.map(map) : [])
        case .points(let points): return .points(isUsable ? points.map(map) : [])
        }
    }
}
