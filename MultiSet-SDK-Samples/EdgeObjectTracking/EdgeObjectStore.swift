/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import UIKit

enum EdgeObjectEntryState: Equatable {
    case loading
    case unavailable(reason: String)
    case available
    case downloading(progress: Double)
    case preparing
    case ready(EdgeObjectModel)
    case failed(message: String)
}

struct EdgeObjectEntry: Identifiable, Equatable {
    let code: String
    var object: EdgeObject?
    var thumbnail: UIImage?
    var state: EdgeObjectEntryState

    var id: String { code }
    var title: String { object?.displayName ?? code }
}

/// The picker's model: one entry per configured code, its details from the API, its download and
/// its unpacked model. Fetches with the SDK's current token and never retries a 401.
@MainActor
final class EdgeObjectStore: ObservableObject {
    typealias Unpack = (_ bundle: URL, _ cacheDirectory: URL,
                        _ completion: @escaping (Result<EdgeObjectModel, Error>) -> Void) -> Void

    @Published private(set) var entries: [EdgeObjectEntry]
    @Published var sessionExpired = false

    let storage: EdgeObjectStorage
    private let api: EdgeObjectAPI
    private let unpack: Unpack
    private var detailsJSON: [String: Data] = [:]

    init(codes: [String], api: EdgeObjectAPI, storage: EdgeObjectStorage = EdgeObjectStorage(), unpack: @escaping Unpack) {
        self.api = api
        self.storage = storage
        self.unpack = unpack
        entries = codes.map { EdgeObjectEntry(code: $0, object: nil, thumbnail: nil, state: .loading) }
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for code in entries.map(\.code) {
                group.addTask { await self.refreshEntry(code: code) }
            }
        }
    }

    func download(code: String) async {
        guard let object = entry(code)?.object, object.availability == .ready,
              let id = object.id, let key = object.modelFileKey, let json = detailsJSON[code] else { return }
        set(code, .downloading(progress: 0))
        do {
            let url = try await api.signedURL(forKey: key)
            try await api.download(url, to: storage.bundleURL(objectId: id)) { progress in
                Task { @MainActor in self.set(code, .downloading(progress: progress)) }
            }
            await loadMesh(object: object, replacing: true)
            try storage.saveDetails(json, objectId: id)
            await prepare(code: code)
        } catch {
            fail(code, error)
        }
    }

    /// Unpacks a downloaded bundle to read the model's size and mesh. Only a bundle the library
    /// refuses is deleted, so that Retry downloads it again; any other failure keeps it.
    func prepare(code: String) async {
        guard let id = entry(code)?.object?.id else { return }
        set(code, .preparing)
        let result: Result<EdgeObjectModel, Error> = await withCheckedContinuation { continuation in
            unpack(storage.bundleURL(objectId: id), storage.cacheDirectory(objectId: id)) { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let model):
            set(code, .ready(model))
        case .failure(let error):
            if (error as? EotError)?.isBundleRefused == true {
                try? storage.delete(objectId: id)
            }
            set(code, .failed(message: "Loading failed: \(error.localizedDescription)"))
        }
    }

    func retry(code: String) async {
        guard let object = entry(code)?.object else {
            await refreshEntry(code: code)
            return
        }
        if storage.hasCurrentBundle(for: object) {
            await prepare(code: code)
        } else {
            await download(code: code)
        }
    }

    func delete(code: String) {
        guard let id = entry(code)?.object?.id else { return }
        try? storage.delete(objectId: id)
        set(code, .available)
    }

    func isDownloaded(code: String) -> Bool {
        if case .ready = entry(code)?.state { return true }
        return false
    }

    private func refreshEntry(code: String) async {
        switch entry(code)?.state {
        case .downloading, .preparing: return
        default: break
        }
        do {
            let json = try await api.detailsJSON(code: code)
            #if DEBUG
            print("EdgeObjectTracking >> \(code): \(String(decoding: json, as: UTF8.self))")
            #endif
            let object = try EdgeObjectAPI.decode(json)
            detailsJSON[code] = json
            update(code) { $0.object = object }
            if let reason = object.availability.reason {
                set(code, .unavailable(reason: reason))
            } else if storage.hasCurrentBundle(for: object) {
                await loadMesh(object: object, replacing: false)
                if case .ready = entry(code)?.state {} else { await prepare(code: code) }
            } else {
                set(code, .available)
            }
            await loadThumbnail(code: code, object: object)
        } catch {
            fail(code, error)
        }
    }

    /// The GLB the tracked outline is drawn from. Without it the tracking screen falls back to the
    /// tracker's own outline, so a failure here never fails the object.
    private func loadMesh(object: EdgeObject, replacing: Bool) async {
        guard let id = object.id, let key = object.meshKey, !key.isEmpty else { return }
        let file = storage.meshURL(objectId: id)
        if !replacing && FileManager.default.fileExists(atPath: file.path) { return }
        do {
            try await api.download(try await api.signedURL(forKey: key), to: file) { _ in }
        } catch {
            print("EdgeObjectTracking >> mesh for \(object.objectCode): \(error.localizedDescription)")
        }
    }

    /// A thumbnail that fails to arrive leaves the placeholder; it never fails the object.
    private func loadThumbnail(code: String, object: EdgeObject) async {
        guard let id = object.id, entry(code)?.thumbnail == nil else { return }
        let file = storage.thumbnailURL(objectId: id)
        if let image = UIImage(contentsOfFile: file.path) {
            update(code) { $0.thumbnail = image }
            return
        }
        guard let key = object.thumbnailKey, !key.isEmpty else { return }
        do {
            let data = try await api.data(try await api.signedURL(forKey: key))
            guard let image = UIImage(data: data) else { return }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            update(code) { $0.thumbnail = image }
        } catch {
            print("EdgeObjectTracking >> thumbnail for \(code): \(error.localizedDescription)")
        }
    }

    private func fail(_ code: String, _ error: Error) {
        if let apiError = error as? EdgeObjectAPIError {
            switch apiError {
            case .unauthorized:
                sessionExpired = true
                set(code, .failed(message: apiError.localizedDescription))
            case .notFound:
                set(code, .unavailable(reason: "Not found"))
            default:
                set(code, .failed(message: apiError.localizedDescription))
            }
        } else {
            set(code, .failed(message: error.localizedDescription))
        }
    }

    private func entry(_ code: String) -> EdgeObjectEntry? {
        entries.first { $0.code == code }
    }

    private func set(_ code: String, _ state: EdgeObjectEntryState) {
        update(code) { $0.state = state }
    }

    private func update(_ code: String, _ change: (inout EdgeObjectEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.code == code }) else { return }
        change(&entries[index])
    }
}
