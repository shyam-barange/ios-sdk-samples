/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation
import Metal
import MultiSetSDK
import RealityKit
import simd
import UIKit

/// One object's outline, held still: the adapter's `OutlineMeshRenderer` (internal to `MultiSetSDK`)
/// as the edge screen uses it, so the sample builds against the released package's public API.
///
/// Two entities per primitive: an `OcclusionMaterial` mesh that hides the interior, and a shell
/// pushed out along the normals with its triangles wound the other way, so default back-face
/// culling leaves only the part that pokes out past the occluder.
final class EdgeOutlineRenderer {
    /// OutlineMat's purple at twice its strength, in the shader's linear values.
    static let purple = SIMD3<Float>(0.639, 0.203, 1.0)

    private var container: Entity?
    private var isLoading = false
    private var outlineMaterial: CustomMaterial?
    private let occlusionMaterial = OcclusionMaterial()
    /// How far the shell stands out from the mesh, in metres of model space.
    private let outlineWidth: Float
    private let color: SIMD3<Float>

    init(outlineWidth: Float, color: SIMD3<Float> = EdgeOutlineRenderer.purple) {
        self.outlineWidth = outlineWidth
        self.color = color
        loadMetalShaders()
    }

    private func loadMetalShaders() {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else { return }
        do {
            var material = try CustomMaterial(
                surfaceShader: CustomMaterial.SurfaceShader(named: "edgeOutlineSurface", in: library),
                geometryModifier: CustomMaterial.GeometryModifier(named: "edgeOutlineGeometry", in: library),
                lightingModel: .unlit
            )
            material.baseColor.tint = .white
            material.blending = .transparent(opacity: 1.0)
            // x = outline width, read by the geometry modifier; yzw = the line's colour
            material.custom.value = SIMD4<Float>(outlineWidth, color.x, color.y, color.z)
            outlineMaterial = material
        } catch {
            // Falls back to the plain material in loadAndRender
        }
    }

    func renderOutlineMesh(meshResult: ObjectMeshAsset, parentEntity: Entity) {
        // `parent != nil`: an outline orphaned by a torn-down view must not block its replacement.
        if let container, container.parent != nil { return }
        guard !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            await loadAndRender(meshResult, parent: parentEntity)
            isLoading = false
        }
    }

    /// Whether the outline is attached to a live scene.
    func hasMesh() -> Bool {
        container?.scene != nil
    }

    @MainActor
    private func loadAndRender(_ meshResult: ObjectMeshAsset, parent: Entity) async {
        do {
            // Deriving the shell's normals is the expensive half of a mesh, so it runs off main.
            let glbData = meshResult.glbData
            let rootNodes = try await Task.detached(priority: .userInitiated) {
                try GLBParser.parse(glbData, preparing: EdgeOutlineRenderer.prepareForOutline)
            }.value
            let outline: any Material = outlineMaterial ?? makeFallbackMaterial()
            let entity = Entity()
            for node in rootNodes {
                entity.addChild(await buildEntity(node, parent: matrix_identity_float4x4, outline: outline))
            }
            parent.addChild(entity)
            container = entity
        } catch {
            // No outline: the 2D outline stays in its place
        }
    }

    /// Every node's transform is baked into its vertices, so the entities carry none: the shell is
    /// pushed out in the mesh's own units, and under a GLB node scaled by 0.012 (a model exported in
    /// other units) a 3 mm line came out 0.035 mm wide.
    @MainActor
    private func buildEntity(_ node: GLBNode<OutlinePrimitive>, parent: simd_float4x4, outline: any Material) async -> Entity {
        let entity = Entity()
        let matrix = parent * node.transform.matrix
        let linear = simd_float3x3(columns: (simd_make_float3(matrix.columns.0), simd_make_float3(matrix.columns.1),
                                             simd_make_float3(matrix.columns.2)))
        let determinant = simd_determinant(linear)
        let normalMatrix = abs(determinant) > 1e-20 ? linear.inverse.transpose : matrix_identity_float3x3
        for primitive in node.primitives {
            let positions = primitive.positions.map { simd_make_float3(matrix * SIMD4($0, 1)) }
            let normals = primitive.normals.map { normal -> SIMD3<Float> in
                let turned = normalMatrix * normal
                return simd_length_squared(turned) > 1e-20 ? simd_normalize(turned) : SIMD3<Float>(0, 1, 0)
            }
            // A mirroring node turns every triangle over, which would swap the occluder and the shell.
            let mirrored = determinant < 0

            var occlusionDescriptor = MeshDescriptor(name: "occlusion_mesh")
            occlusionDescriptor.positions = MeshBuffer(positions)
            occlusionDescriptor.primitives = .triangles(mirrored ? primitive.shellIndices : primitive.indices)
            occlusionDescriptor.normals = MeshBuffer(normals)

            var outlineDescriptor = MeshDescriptor(name: "outline_mesh")
            outlineDescriptor.positions = MeshBuffer(positions)
            outlineDescriptor.primitives = .triangles(mirrored ? primitive.indices : primitive.shellIndices)
            outlineDescriptor.normals = MeshBuffer(normals)

            if let occlusion = try? MeshResource.generate(from: [occlusionDescriptor]),
               let shell = try? MeshResource.generate(from: [outlineDescriptor]) {
                entity.addChild(ModelEntity(mesh: occlusion, materials: [occlusionMaterial]))
                entity.addChild(ModelEntity(mesh: shell, materials: [outline]))
            }
            // MeshResource.generate must run on main; yielding per primitive lets ARView draw between them.
            await Task.yield()
        }
        for child in node.children {
            entity.addChild(await buildEntity(child, parent: matrix, outline: outline))
        }
        return entity
    }

    /// No shader library: a still shell in the line's colour, which the occluder still reduces to an outline.
    private func makeFallbackMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1))
        return material
    }

    private static func prepareForOutline(_ raw: GLBRawPrimitive) -> OutlinePrimitive? {
        guard !raw.positions.isEmpty else { return nil }
        let indices = raw.indices ?? raw.sequentialIndices
        // Scanned object meshes carry no normals, and the shell is expanded along them.
        let normals = raw.normals.count == raw.positions.count
            ? raw.normals
            : smoothNormals(positions: raw.positions, indices: indices)
        return OutlinePrimitive(positions: raw.positions, normals: normals, indices: indices,
                                shellIndices: reversedWinding(indices))
    }

    /// Angle-weighted vertex normals, welded across duplicated vertices: normals that stop at a
    /// texture seam would open a gap in the shell exactly where the outline should be continuous.
    private static func smoothNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var weldIndex = [Int](repeating: 0, count: positions.count)
        var buckets: [SIMD3<Int32>: Int] = [:]
        var accumulated: [SIMD3<Float>] = []
        for (i, p) in positions.enumerated() {
            // Positions within 0.1 mm are one vertex
            let key = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
            if let existing = buckets[key] {
                weldIndex[i] = existing
            } else {
                buckets[key] = accumulated.count
                weldIndex[i] = accumulated.count
                accumulated.append(.zero)
            }
        }

        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let pa = positions[a], pb = positions[b], pc = positions[c]
            let faceNormal = cross(pb - pa, pc - pa)
            guard length_squared(faceNormal) > 1e-18 else { continue }
            let unit = normalize(faceNormal)
            accumulated[weldIndex[a]] += unit * angle(pb - pa, pc - pa)
            accumulated[weldIndex[b]] += unit * angle(pc - pb, pa - pb)
            accumulated[weldIndex[c]] += unit * angle(pa - pc, pb - pc)
        }

        return weldIndex.map { welded in
            let n = accumulated[welded]
            return length_squared(n) > 1e-12 ? normalize(n) : SIMD3<Float>(0, 1, 0)
        }
    }

    private static func angle(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Float {
        let denominator = length(u) * length(v)
        guard denominator > 1e-12 else { return 0 }
        return acos(min(max(dot(u, v) / denominator, -1), 1))
    }

    private static func reversedWinding(_ indices: [UInt32]) -> [UInt32] {
        var result = indices
        var i = 0
        while i + 2 < result.count {
            result.swapAt(i + 1, i + 2)
            i += 3
        }
        return result
    }
}

/// One primitive's occluder and shell, prepared off the main thread.
private struct OutlinePrimitive: Sendable {
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
    let shellIndices: [UInt32]
}
