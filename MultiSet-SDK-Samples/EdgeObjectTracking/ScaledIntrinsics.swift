/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

/// Pinhole intrinsics of an image the tracker is given, after any downscaling.
struct ScaledIntrinsics: Equatable {
    let fu: Float
    let fv: Float
    let ppu: Float
    let ppv: Float

    init(fu: Float, fv: Float, ppu: Float, ppv: Float) {
        self.fu = fu
        self.fv = fv
        self.ppu = ppu
        self.ppv = ppv
    }

    /// The intrinsics of a full image scaled by `factor` (target pixels per source pixel), keeping
    /// pixel centres: a pixel's centre c lands at (c + 0.5) * factor - 0.5.
    init(fu: Float, fv: Float, ppu: Float, ppv: Float, factor: Float) {
        self.init(fu: fu * factor, fv: fv * factor,
                  ppu: (ppu + 0.5) * factor - 0.5, ppv: (ppv + 0.5) * factor - 0.5)
    }
}
