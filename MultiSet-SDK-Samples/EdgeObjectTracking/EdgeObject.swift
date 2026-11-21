/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

/// A start view saved with the object on the dashboard: a row-major 4x4 object-to-camera pose for
/// an upright screen (x right, y down, z forward), with the phone held as `isLandscape` says.
struct EdgeGuideView: Equatable {
    let name: String
    let isLandscape: Bool
    let pose: [Float]

    var title: String { isLandscape ? "\(name) (landscape)" : name }

    /// The guide stepper's label: the selected view, its place when there are several, or the free guide.
    static func label(index: Int, in views: [EdgeGuideView]) -> String {
        guard index >= 0, index < views.count else { return "Free guide" }
        return views.count == 1 ? views[index].title : "\(views[index].title) · \(index + 1) of \(views.count)"
    }
}

enum EdgeObjectAvailability: Equatable {
    case ready
    case notEdgeObject
    case processing
    case failed(error: String?)

    var reason: String? {
        switch self {
        case .ready: return nil
        case .notEdgeObject: return "Not an edge object"
        case .processing: return "Still processing on the dashboard"
        case .failed(let error):
            if let error, !error.isEmpty { return "Processing failed on the dashboard: \(error)" }
            return "Processing failed on the dashboard"
        }
    }
}

/// The fields of `GET /v1/vps/object/{objectCode}` this sample uses. Everything but `objectCode`
/// is optional and unknown fields are ignored, so a changed response degrades to a reason, not a crash.
struct EdgeObject: Decodable, Equatable {
    let id: String?
    let objectCode: String
    let objectName: String?
    let trackingMode: String?
    let thumbnailKey: String?
    /// The object's GLB, which the tracked outline is drawn from.
    let meshKey: String?
    let modelStatus: String?
    let modelFileKey: String?
    let modelError: String?
    let updatedAt: String?
    let guideViews: [EdgeGuideView]
    let startMode: String?
    let startModelStatus: String?

    var displayName: String {
        if let objectName, !objectName.isEmpty { return objectName }
        return objectCode
    }

    /// `startMode` "auto": the server finds the object in a camera picture, so no guide is needed.
    /// Until its start model is ready, the object starts from the guide like any other.
    var startsAutomatically: Bool { startMode == "auto" && startModelStatus == "ready" }

    var availability: EdgeObjectAvailability {
        guard trackingMode == "edge" else { return .notEdgeObject }
        switch modelStatus {
        case "ready":
            return (modelFileKey?.isEmpty == false) ? .ready : .processing
        case "failed":
            return .failed(error: modelError)
        default:
            return .processing
        }
    }

    static func decode(_ data: Data) throws -> EdgeObject {
        try JSONDecoder().decode(EdgeObject.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case objectCode, objectName, trackingMode, thumbnail, trackingModel, eotModel, updatedAt, guideViews, objectMesh
        case startMode, startModel
    }

    private enum MeshKeys: String, CodingKey {
        case meshLink
    }

    private enum ModelKeys: String, CodingKey {
        case status, file, error
    }

    private struct RawGuideView: Decodable {
        let name: String?
        let orientation: String?
        let pose: [Float]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        objectCode = try container.decode(String.self, forKey: .objectCode)
        objectName = try container.decodeIfPresent(String.self, forKey: .objectName)
        trackingMode = try container.decodeIfPresent(String.self, forKey: .trackingMode)
        thumbnailKey = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        meshKey = (try? container.nestedContainer(keyedBy: MeshKeys.self, forKey: .objectMesh))
            .flatMap { try? $0.decodeIfPresent(String.self, forKey: .meshLink) }
        // `eotModel` is the field's name before the server renamed it; details cached on disk still use it.
        if let model = (try? container.nestedContainer(keyedBy: ModelKeys.self, forKey: .trackingModel))
            ?? (try? container.nestedContainer(keyedBy: ModelKeys.self, forKey: .eotModel)) {
            modelStatus = try? model.decodeIfPresent(String.self, forKey: .status)
            modelFileKey = try? model.decodeIfPresent(String.self, forKey: .file)
            modelError = try? model.decodeIfPresent(String.self, forKey: .error)
        } else {
            modelStatus = nil
            modelFileKey = nil
            modelError = nil
        }
        startMode = try? container.decodeIfPresent(String.self, forKey: .startMode)
        startModelStatus = (try? container.nestedContainer(keyedBy: ModelKeys.self, forKey: .startModel))
            .flatMap { try? $0.decodeIfPresent(String.self, forKey: .status) }
        let raw = (try? container.decodeIfPresent([RawGuideView].self, forKey: .guideViews)) ?? []
        guideViews = raw.enumerated().compactMap { index, view in
            guard let pose = view.pose, pose.count == 16 else { return nil }
            return EdgeGuideView(name: view.name ?? "View \(index + 1)",
                                 isLandscape: view.orientation == "landscape", pose: pose)
        }
    }
}
