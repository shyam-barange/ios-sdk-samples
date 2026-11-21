/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation
import simd

/// What the unpacked bundle says about the object: the mesh to draw, the distance its models were
/// generated for, and its size.
struct EdgeObjectModel: Equatable {
    let meshURL: URL
    let modelDistance: Float
    let unitInMeter: Float
    /// The bounding box in the model's coordinates, in metres.
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    /// Width, height and depth of the bounding box in millimetres.
    var sizeMm: SIMD3<Float> { (boundsMax - boundsMin) * 1000 }

    var sizeText: String { String(format: "%.0f × %.0f × %.0f mm", sizeMm.x, sizeMm.y, sizeMm.z) }

    /// Reads `eot.json` and the mesh it names from the library's `<cache>/object` folder.
    static func read(unpackedDirectory: URL) throws -> EdgeObjectModel {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: unpackedDirectory.appendingPathComponent("eot.json")))
            as? [String: Any] ?? [:]
        let meshURL = unpackedDirectory.appendingPathComponent(json["mesh"] as? String ?? "model.obj")
        let unitInMeter = (json["unitInMeter"] as? NSNumber)?.floatValue ?? 1
        let bounds = try ObjMesh(url: meshURL).bounds
        return EdgeObjectModel(meshURL: meshURL,
                               modelDistance: (json["modelDistance"] as? NSNumber)?.floatValue ?? 0.4,
                               unitInMeter: unitInMeter,
                               boundsMin: bounds.min * unitInMeter,
                               boundsMax: bounds.max * unitInMeter)
    }
}
