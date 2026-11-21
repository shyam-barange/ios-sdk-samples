/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation
import simd

/// Arithmetic on the tracker's row-major 4x4 poses (model to camera), as in the EOT samples.
enum PoseMath {
    static func transform(_ pose: [Float], _ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        SIMD3(pose[0] * x + pose[1] * y + pose[2] * z + pose[3],
              pose[4] * x + pose[5] * y + pose[6] * z + pose[7],
              pose[8] * x + pose[9] * y + pose[10] * z + pose[11])
    }

    static func distance(_ pose: [Float]) -> Float {
        (pose[3] * pose[3] + pose[7] * pose[7] + pose[11] * pose[11]).squareRoot()
    }

    /// The pose moved along its line of sight to `distance` metres from the camera.
    static func moved(_ pose: [Float], toDistance distance: Float) -> [Float] {
        var out = pose
        let k = distance / Self.distance(pose)
        out[3] *= k
        out[7] *= k
        out[11] *= k
        return out
    }

    /// The model upright on a portrait screen, turned by yaw and pitch, `distance` metres straight
    /// ahead, in the axes of the landscape image the camera delivers (x right, y down).
    static func guidePose(yaw: Float, pitch: Float, distance: Float) -> [Float] {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        // Rotation in screen axes (x right, y up, z towards the viewer): Rx(pitch) * Ry(yaw).
        let r: [Float] = [cy, 0, sy,
                          sp * sy, cp, -sp * cy,
                          -cp * sy, sp, cp * cy]
        // Portrait screen to sensor image: screen right is image up, screen up is image left,
        // towards the viewer is towards the camera.
        var out = [Float](repeating: 0, count: 16)
        for c in 0..<3 {
            out[c] = -r[3 + c]
            out[4 + c] = -r[c]
            out[8 + c] = -r[6 + c]
        }
        out[11] = distance
        out[15] = 1
        return out
    }

    /// The model's transform in the AR world: the tracker's camera axes (x right, y down, z forward)
    /// turned into ARKit's (x right, y up, z back), then placed by the same frame's camera transform.
    static func worldTransform(trackerPose pose: [Float], cameraTransform: simd_float4x4) -> simd_float4x4 {
        let objectInCamera = simd_float4x4(rows: [
            SIMD4(pose[0], pose[1], pose[2], pose[3]),
            SIMD4(pose[4], pose[5], pose[6], pose[7]),
            SIMD4(pose[8], pose[9], pose[10], pose[11]),
            SIMD4(0, 0, 0, 1)])
        let trackerToARKit = simd_float4x4(diagonal: SIMD4(1, -1, -1, 1))
        return cameraTransform * trackerToARKit * objectInCamera
    }

    /// The camera's place in the AR world in the tracker's camera axes, row-major, for
    /// `EotTracker.setCameraPose`.
    static func trackerCamera(_ cameraTransform: simd_float4x4) -> [Float] {
        let m = cameraTransform * simd_float4x4(diagonal: SIMD4(1, -1, -1, 1))
        return (0..<4).flatMap { row in [m[0][row], m[1][row], m[2][row], m[3][row]] }
    }

    /// The inverse of `worldTransform`: a transform in the AR world as the tracker's row-major pose.
    static func trackerPose(world: simd_float4x4, cameraTransform: simd_float4x4) -> [Float] {
        let trackerToARKit = simd_float4x4(diagonal: SIMD4(1, -1, -1, 1))
        let m = (cameraTransform * trackerToARKit).inverse * world
        return (0..<4).flatMap { row in [m[0][row], m[1][row], m[2][row], m[3][row]] }
    }

    /// A saved guide view (upright screen, x right, y down) as a pose in the landscape camera
    /// image, where the screen's right is the image's up and the screen's down is the image's right.
    static func guidePose(fromView view: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: 16)
        for c in 0..<4 {
            out[c] = view[4 + c]
            out[4 + c] = -view[c]
            out[8 + c] = view[8 + c]
            out[12 + c] = view[12 + c]
        }
        return out
    }
}

/// The vertices and triangles of an OBJ file.
struct ObjMesh {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(Int, Int, Int)] = []

    init(url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .ascii))
    }

    init(text: String) throws {
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                guard p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) else { continue }
                vertices.append(SIMD3(x, y, z))
            } else if line.hasPrefix("f ") {
                let index = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().compactMap { token -> Int? in
                    guard let k = Int(token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]) else { return nil }
                    return k > 0 ? k - 1 : vertices.count + k
                }
                if index.count >= 3 {
                    for i in 2..<index.count { triangles.append((index[0], index[i - 1], index[i])) }
                }
            }
        }
        if vertices.isEmpty { throw CocoaError(.fileReadCorruptFile) }
    }

    /// Up to `maxPoints` vertices, evenly thinned, as x,y,z triples.
    func thinnedPoints(max maxPoints: Int) -> [Float] {
        let step = max(1, vertices.count / maxPoints)
        var points: [Float] = []
        for i in stride(from: 0, to: vertices.count, by: step) {
            points += [vertices[i].x, vertices[i].y, vertices[i].z]
        }
        return points
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = vertices.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for vertex in vertices {
            lo = pointwiseMin(lo, vertex)
            hi = pointwiseMax(hi, vertex)
        }
        return (lo, hi)
    }

    var boundingBoxSize: SIMD3<Float> { bounds.max - bounds.min }
}

/// Steadies the tracked pose for display, the EOT samples' One-Euro filter: strong while the object
/// is still, light while it moves. It works in the AR world, so moving the phone adds no lag; the
/// tracker keeps its raw pose.
struct PoseSmoother {
    static let minCutoff: Float = 0.5    // Hz, while still
    static let speedCutoffT: Float = 10  // Hz added per m/s of movement
    static let speedCutoffR: Float = 1   // Hz added per rad/s of turning
    /// A larger jump (a re-acquisition or a restart) is taken at once.
    static let jumpMetres: Float = 0.1
    static let jumpRadians: Float = 0.5

    private var position = SIMD3<Float>()
    private var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var speedT: Float = 0
    private var speedR: Float = 0
    private var lastTime: TimeInterval = -1

    mutating func reset() {
        lastTime = -1
    }

    /// `world` is the tracked object's transform in the AR world at the camera frame's `time`.
    mutating func update(world: simd_float4x4, time: TimeInterval) -> simd_float4x4 {
        let p = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let r = simd_quatf(world)
        let dt = Float(time - lastTime)
        let turn = 2 * acos(min(1, abs(simd_dot(rotation.vector, r.vector))))
        if lastTime < 0 || dt <= 0 || dt > 0.5 || simd_distance(p, position) > Self.jumpMetres || turn > Self.jumpRadians {
            position = p
            rotation = r
            speedT = 0
            speedR = 0
        } else {
            let aSpeed = Self.alpha(1, dt)
            speedT += aSpeed * (simd_distance(p, position) / dt - speedT)
            speedR += aSpeed * (turn / dt - speedR)
            position += Self.alpha(Self.minCutoff + Self.speedCutoffT * speedT, dt) * (p - position)
            rotation = simd_slerp(rotation, r, Self.alpha(Self.minCutoff + Self.speedCutoffR * speedR, dt))
        }
        lastTime = time
        var steady = simd_float4x4(rotation)
        steady.columns.3 = SIMD4(position, 1)
        return steady
    }

    private static func alpha(_ cutoff: Float, _ dt: Float) -> Float {
        let r = 2 * Float.pi * cutoff * dt
        return r / (r + 1)
    }
}
