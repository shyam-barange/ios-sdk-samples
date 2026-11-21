/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

enum EdgeObjectUnpacker {
    /// Unpacks a bundle with a throwaway tracker so the mesh and `eot.json` can be read before any
    /// tracking. The first unpack takes seconds and writes about 300 MB; the completion runs on main.
    static func unpack(bundle: URL, cacheDirectory: URL, completion: @escaping (Result<EdgeObjectModel, Error>) -> Void) {
        EotThread.start("eot-unpack") {
            let result = Result {
                let unpacker = try EotTracker()
                // Any intrinsics will do: the tracker is only used for the unpacking.
                try unpacker.setColorIntrinsics(fu: 500, fv: 500, ppu: 320, ppv: 240, width: 640, height: 480)
                try unpacker.loadBundle(bundle, cacheDirectory: cacheDirectory)
                return try EdgeObjectModel.read(unpackedDirectory: cacheDirectory.appendingPathComponent("object", isDirectory: true))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
