/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

/// Where an edge object lives on this device: the download and its details under Application
/// Support, the library's unpacked copy (about 300 MB, purgeable) under Caches.
struct EdgeObjectStorage {
    let supportRoot: URL
    let cacheRoot: URL

    init() {
        let files = FileManager.default
        self.init(
            supportRoot: files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EdgeObjectTracking", isDirectory: true),
            cacheRoot: files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EdgeObjectTracking", isDirectory: true))
    }

    init(supportRoot: URL, cacheRoot: URL) {
        self.supportRoot = supportRoot
        self.cacheRoot = cacheRoot
    }

    func supportDirectory(objectId: String) -> URL {
        supportRoot.appendingPathComponent(objectId, isDirectory: true)
    }

    func cacheDirectory(objectId: String) -> URL {
        cacheRoot.appendingPathComponent(objectId, isDirectory: true)
    }

    func bundleURL(objectId: String) -> URL {
        supportDirectory(objectId: objectId).appendingPathComponent("eot.bin")
    }

    func meshURL(objectId: String) -> URL {
        supportDirectory(objectId: objectId).appendingPathComponent("mesh.glb")
    }

    func thumbnailURL(objectId: String) -> URL {
        supportDirectory(objectId: objectId).appendingPathComponent("thumbnail")
    }

    func detailsURL(objectId: String) -> URL {
        supportDirectory(objectId: objectId).appendingPathComponent("object.json")
    }

    func saveDetails(_ data: Data, objectId: String) throws {
        try FileManager.default.createDirectory(at: supportDirectory(objectId: objectId), withIntermediateDirectories: true)
        try data.write(to: detailsURL(objectId: objectId), options: .atomic)
    }

    func savedDetails(objectId: String) -> EdgeObject? {
        guard let data = try? Data(contentsOf: detailsURL(objectId: objectId)) else { return nil }
        return try? EdgeObject.decode(data)
    }

    /// The downloaded bundle is current while the details it was saved with still name the same
    /// file and `updatedAt`; re-processing changes both the file's contents and `updatedAt`.
    func hasCurrentBundle(for object: EdgeObject) -> Bool {
        guard let id = object.id, FileManager.default.fileExists(atPath: bundleURL(objectId: id).path),
              let saved = savedDetails(objectId: id) else { return false }
        return saved.updatedAt == object.updatedAt && saved.modelFileKey == object.modelFileKey
    }

    func delete(objectId: String) throws {
        let files = FileManager.default
        for directory in [supportDirectory(objectId: objectId), cacheDirectory(objectId: objectId)]
        where files.fileExists(atPath: directory.path) {
            try files.removeItem(at: directory)
        }
    }
}
