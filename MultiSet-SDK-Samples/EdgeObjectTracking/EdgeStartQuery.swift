/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd

/// One camera picture as `POST /v1/vps/object/query` takes it: upright, with the camera pose that
/// matches the upright picture.
struct EdgeStartFrame {
    let jpeg: Data
    let fx: Float
    let fy: Float
    let px: Float
    let py: Float
    let width: Int
    let height: Int
    let queryCamera: simd_float4x4
    /// Where the object is in the picture; without one the server looks in the middle half.
    let box: EdgeQueryBox?
}

/// The SDK's portrait object query, rebuilt here because the core's `FramePreprocessor` is internal.
/// The host check compares the two, so keep them in step.
enum EdgeStartQuery {
    static let imageWidth = 720
    static let imageHeight = 960
    static let jpegQuality: CGFloat = 0.9
    private static let context = CIContext()

    /// Rotates the landscape sensor picture upright for the portrait screen and swaps the intrinsics to match.
    static func prepare(pixelBuffer: CVPixelBuffer, intrinsics k: simd_float3x3, cameraTransform: simd_float4x4,
                        box: EdgeQueryBox? = nil) -> EdgeStartFrame? {
        let sourceWidth = Float(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = Float(CVPixelBufferGetHeight(pixelBuffer))
        let scaleX = Float(imageWidth) / sourceHeight
        let scaleY = Float(imageHeight) / sourceWidth
        guard let jpeg = encodeJPEG(pixelBuffer) else { return nil }
        return EdgeStartFrame(jpeg: jpeg,
                              fx: k[1][1] * scaleX, fy: k[0][0] * scaleY,
                              px: (sourceHeight - k[2][1]) * scaleX, py: k[2][0] * scaleY,
                              width: imageWidth, height: imageHeight,
                              queryCamera: queryCamera(cameraTransform), box: box)
    }

    /// ARKit's camera is landscape; the upright picture's camera is rolled 90° about its own z.
    static func queryCamera(_ cameraTransform: simd_float4x4) -> simd_float4x4 {
        cameraTransform * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
    }

    static func body(objectCode: String, frame: EdgeStartFrame, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("objectCode", objectCode)
        field("isRightHanded", "true")
        field("fx", String(frame.fx))
        field("fy", String(frame.fy))
        field("px", String(frame.px))
        field("py", String(frame.py))
        field("width", String(frame.width))
        field("height", String(frame.height))
        if let box = frame.box {
            field("boxX", String(box.x))
            field("boxY", String(box.y))
            field("boxWidth", String(box.width))
            field("boxHeight", String(box.height))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"queryImage\"; filename=\"image.JPG\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(frame.jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func encodeJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let upright = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: CGFloat(imageWidth) / upright.extent.width,
                                                               y: CGFloat(imageHeight) / upright.extent.height))
        return context.jpegRepresentation(
            of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality])
    }
}

/// The object query's answer: where the query camera was, in the object's coordinates.
struct EdgeStartResponse: Decodable {
    struct Position: Decodable { let x, y, z: Float }
    struct Rotation: Decodable { let x, y, z, w: Float }

    let poseFound: Bool
    let position: Position?
    let rotation: Rotation?
    let confidence: Double?

    /// The object in the AR world, as the SDK's object tracking places it: `queryCamera * response.inverse`.
    func worldPose(queryCamera: simd_float4x4) -> simd_float4x4? {
        guard poseFound, let position, let rotation else { return nil }
        var cameraInObject = simd_float4x4(simd_quatf(ix: rotation.x, iy: rotation.y, iz: rotation.z, r: rotation.w))
        cameraInObject.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return queryCamera * cameraInObject.inverse
    }
}
