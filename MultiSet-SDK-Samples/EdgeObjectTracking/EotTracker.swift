/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

enum EotColorFormat: Int32 {
    case bgr = 0, rgb = 1, rgba = 2, bgra = 3

    var bytesPerPixel: Int { self == .rgba || self == .bgra ? 4 : 3 }
}

/// 16-bit values times the depth scale, or 32-bit float metres.
enum EotDepthFormat: Int32 {
    case u16 = 0, f32 = 1

    var bytesPerPixel: Int { self == .f32 ? 4 : 2 }
}

/// A camera image as the tracker reads it. The caller keeps the memory valid for the call.
struct EotImage {
    let pixels: UnsafeRawPointer
    let rowBytes: Int
}

enum EotThread {
    /// The tracking core keeps large matrices on the stack, so every thread that calls `eot_*` gets 8 MB.
    @discardableResult
    static func start(_ name: String, _ body: @escaping () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.name = name
        thread.stackSize = 8 << 20
        thread.start()
        return thread
    }
}

/// One tracker for one rigid object over the `eot_*` C interface. Poses are row-major 4x4 floats,
/// model to colour camera, in metres, with x right, y down and z forward in the image as delivered.
/// Not thread-safe: one instance from one thread at a time.
final class EotTracker {
    #if targetEnvironment(simulator)
    static let isSupported = false
    static var version: String { "unavailable" }
    #else
    static let isSupported = true
    static var version: String { String(cString: eot_version()) }
    private let handle: OpaquePointer
    #endif

    private var colorSize = (width: 0, height: 0)
    private var depthSize = (width: 0, height: 0)
    private(set) var usesDepth = false
    private(set) var isLoaded = false
    private(set) var isTracking = false

    init() throws {
        #if targetEnvironment(simulator)
        throw EotError.unsupported
        #else
        guard let h = eot_create() else {
            throw EotError(operation: "create", code: -1, detail: "the native tracker could not be created")
        }
        handle = h
        #endif
    }

    deinit {
        #if !targetEnvironment(simulator)
        eot_destroy(handle)
        #endif
    }

    /// Options such as `snap_start=1` or `auto_recover=1`. Call before `loadBundle`.
    func setOption(_ name: String, _ value: String) throws {
        try requireConfigurable()
        #if !targetEnvironment(simulator)
        if eot_set_option(handle, name, value) != 0 {
            throw EotError(operation: "set_option \(name)", code: -1, detail: "unknown option")
        }
        #endif
    }

    func setColorIntrinsics(fu: Float, fv: Float, ppu: Float, ppv: Float, width: Int, height: Int) throws {
        try requireConfigurable()
        #if !targetEnvironment(simulator)
        eot_set_color_intrinsics(handle, fu, fv, ppu, ppv, Int32(width), Int32(height))
        #endif
        colorSize = (width, height)
    }

    /// Turns the depth modality on. `depthScale` is metres per unit for 16-bit depth (1 for float metres).
    func setDepthIntrinsics(fu: Float, fv: Float, ppu: Float, ppv: Float, width: Int, height: Int,
                            depthScale: Float) throws {
        try requireConfigurable()
        #if !targetEnvironment(simulator)
        eot_set_depth_intrinsics(handle, fu, fv, ppu, ppv, Int32(width), Int32(height), depthScale)
        #endif
        depthSize = (width, height)
        usesDepth = true
    }

    /// Loads the object from its `eot.bin`. The first load unpacks it into `cacheDirectory/object`
    /// (about 300 MB) and later loads reuse that, so call it off the main thread.
    func loadBundle(_ bundle: URL, cacheDirectory: URL) throws {
        if colorSize.width <= 0 {
            throw EotError(operation: "load_bundle", code: -1, detail: "set the colour intrinsics first")
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        isLoaded = false
        isTracking = false
        #if !targetEnvironment(simulator)
        try check(eot_load_bundle(handle, bundle.path, cacheDirectory.path), "load_bundle")
        #endif
        isLoaded = true
    }

    func setPose(_ pose: [Float]) throws {
        try requireLoaded()
        precondition(pose.count >= 16, "a pose is 16 floats")
        #if !targetEnvironment(simulator)
        pose.withUnsafeBufferPointer { eot_set_pose(handle, $0.baseAddress) }
        #endif
    }

    /// Where the camera is for the next `start` or `step`, from the AR session: row-major camera to
    /// world, in the tracker's camera axes (eot_set_camera_pose). Pass it on every frame whose AR
    /// tracking is normal; the tracker then holds a still object in place while the phone moves.
    func setCameraPose(_ cameraToWorld: [Float]) {
        precondition(cameraToWorld.count >= 16, "a pose is 16 floats")
        #if !targetEnvironment(simulator)
        cameraToWorld.withUnsafeBufferPointer { eot_set_camera_pose(handle, $0.baseAddress) }
        #endif
    }

    func pose() -> [Float] {
        var pose = [Float](repeating: 0, count: 16)
        #if !targetEnvironment(simulator)
        pose.withUnsafeMutableBufferPointer { eot_get_pose(handle, $0.baseAddress) }
        #endif
        return pose
    }

    /// Begins tracking from the pose set with `setPose`, learning the object's colours from this frame.
    func start(color: EotImage, format: EotColorFormat, depth: EotImage? = nil,
               depthFormat: EotDepthFormat = .u16) throws {
        try requireLoaded()
        let depth = try checkedDepth(depth, depthFormat)
        isTracking = false
        #if !targetEnvironment(simulator)
        try check(eot_start(handle, color.pixels.assumingMemoryBound(to: UInt8.self), format.rawValue,
                            Int32(color.rowBytes), depth?.pixels, depthFormat.rawValue,
                            Int32(depth?.rowBytes ?? 0)), "start")
        #endif
        isTracking = true
    }

    func step(color: EotImage, format: EotColorFormat, depth: EotImage? = nil,
              depthFormat: EotDepthFormat = .u16) throws {
        try requireLoaded()
        guard isTracking else { throw EotError(operation: "step", code: -1, detail: "call start before step") }
        let depth = try checkedDepth(depth, depthFormat)
        #if !targetEnvironment(simulator)
        try check(eot_step(handle, color.pixels.assumingMemoryBound(to: UInt8.self), format.rawValue,
                           Int32(color.rowBytes), depth?.pixels, depthFormat.rawValue,
                           Int32(depth?.rowBytes ?? 0)), "step")
        #endif
    }

    func stop() {
        isTracking = false
    }

    /// 0 to 1, how well the pose explains the last frame; -1 when it cannot be judged.
    var quality: Float {
        #if targetEnvironment(simulator)
        return -1
        #else
        return eot_get_quality(handle)
        #endif
    }

    /// The quality relative to what is usual on this run, 0 to 1; -1 when it cannot be judged.
    var confidence: Float {
        #if targetEnvironment(simulator)
        return -1
        #else
        return eot_get_confidence(handle)
        #endif
    }

    var isLost: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return eot_is_lost(handle) != 0
        #endif
    }

    private func checkedDepth(_ depth: EotImage?, _ format: EotDepthFormat) throws -> EotImage? {
        guard usesDepth else { return nil }
        guard let depth else { throw EotError(operation: "step", code: -1, detail: "a depth image is required") }
        if depth.rowBytes != 0 && depth.rowBytes < depthSize.width * format.bytesPerPixel {
            throw EotError(operation: "step", code: -1, detail: "depth rows are shorter than the intrinsics say")
        }
        return depth
    }

    private func requireConfigurable() throws {
        if isLoaded {
            throw EotError(operation: "configure", code: -1, detail: "intrinsics and options cannot change after load")
        }
    }

    private func requireLoaded() throws {
        if !isLoaded { throw EotError(operation: "track", code: -1, detail: "call load first") }
    }

    #if !targetEnvironment(simulator)
    private func check(_ code: Int32, _ operation: String) throws {
        guard code != 0 else { return }
        throw EotError(operation: operation, code: code, detail: String(cString: eot_last_error(handle)))
    }
    #endif
}
