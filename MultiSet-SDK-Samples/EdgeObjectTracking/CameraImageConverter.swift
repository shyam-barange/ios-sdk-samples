/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Accelerate
import CoreVideo

/// Turns ARKit's captured image (4:2:0 Y + CbCr, in the sensor's landscape orientation) into a
/// 640-pixel-wide RGBA image for the tracker. Use from one thread.
final class CameraImageConverter {
    static let targetWidth = 640

    let width: Int
    let height: Int
    /// Source pixels per target pixel.
    let scale: Float
    let rgba: UnsafeMutableRawPointer
    var rgbaRowBytes: Int { width * 4 }

    private let luma: UnsafeMutableRawPointer
    private let chroma: UnsafeMutableRawPointer
    private var conversion = vImage_YpCbCrToARGB()
    private var conversionKey = ""

    init(sourceWidth: Int, sourceHeight: Int) {
        width = Self.targetWidth
        height = Int((Double(sourceHeight) * Double(Self.targetWidth) / Double(sourceWidth)).rounded())
        scale = Float(sourceWidth) / Float(Self.targetWidth)
        rgba = .allocate(byteCount: width * height * 4, alignment: 64)
        luma = .allocate(byteCount: width * height, alignment: 64)
        chroma = .allocate(byteCount: (width / 2) * (height / 2) * 2, alignment: 64)
    }

    deinit {
        rgba.deallocate()
        luma.deallocate()
        chroma.deallocate()
    }

    func matches(_ buffer: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        return Float(w) / Float(width) == scale
            && Int((Double(h) * Double(Self.targetWidth) / Double(w)).rounded()) == height
    }

    /// Fills `rgba` from the camera image. Returns false if the buffer is not bi-planar 4:2:0.
    func convert(_ buffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        var srcY = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                                 height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, 0)),
                                 width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, 0)),
                                 rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        var srcCbCr = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
                                    height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, 1)),
                                    width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, 1)),
                                    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        var dstY = vImage_Buffer(data: luma, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var dstCbCr = vImage_Buffer(data: chroma, height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2),
                                    rowBytes: width)
        var dstRGBA = vImage_Buffer(data: rgba, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                    rowBytes: rgbaRowBytes)
        guard vImageScale_Planar8(&srcY, &dstY, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImageScale_CbCr8(&srcCbCr, &dstCbCr, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              prepareConversion(for: buffer, fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        else { return false }
        let argbToRGBA: [UInt8] = [1, 2, 3, 0]
        return vImageConvert_420Yp8_CbCr8ToARGB8888(&dstY, &dstCbCr, &dstRGBA, &conversion, argbToRGBA, 255,
                                                    vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }

    private func prepareConversion(for buffer: CVPixelBuffer, fullRange: Bool) -> Bool {
        let attached = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let is709 = attached == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        let key = "\(is709 ? "709" : "601")|\(fullRange)"
        if key == conversionKey { return true }
        var range = fullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                      YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                      YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        guard let matrix = is709 ? kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 : kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
              vImageConvert_YpCbCrToARGB_GenerateConversion(matrix, &range, &conversion, kvImage420Yp8_CbCr8,
                                                            kvImageARGB8888, vImage_Flags(kvImageNoFlags))
                == kvImageNoError else { return false }
        conversionKey = key
        return true
    }
}
