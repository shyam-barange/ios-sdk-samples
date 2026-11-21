/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

struct EotError: LocalizedError {
    let operation: String
    let code: Int32
    let detail: String

    static let unsupported = EotError(operation: "create", code: -1, detail: "Edge tracking needs an iPhone")

    /// The library refused the object file itself ("damaged" or "incomplete"), so only a fresh
    /// download can help.
    var isBundleRefused: Bool { operation == "load_bundle" }

    var errorDescription: String? { "\(operation) failed: \(detail.isEmpty ? "error \(code)" : detail)" }
}
