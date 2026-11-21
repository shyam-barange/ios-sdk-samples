/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import ARKit
import Combine
import MultiSetSDK
import RealityKit
import UIKit

enum EdgeTrackingPhase: Equatable {
    case loading(String)
    /// `startMode` "auto": camera pictures go to the server until it finds the object.
    case searching
    case aligning
    case tracking(confidence: Float, lost: Bool)
    case failed(String)
}

/// Live edge tracking in its own ARKit session, a port of the EOT sample's live screen. Each camera
/// frame goes to a worker thread that converts it and steps the tracker. While aligning, the guide is
/// drawn in 2D; once tracked, the object's GLB is drawn with the Object Tracking outline at the
/// tracked pose in the AR world, so RealityKit keeps it in step with the camera image.
final class EdgeTrackingSession: NSObject, ObservableObject, ARSessionDelegate {
    static let minGuideCm = 10.0
    static let maxGuideCm = 300.0
    /// Half the Object Tracking outline's 6 mm, so the line does not hide the object's own edges.
    static let outlineWidth: Float = 0.003
    /// The guide's line, half as wide again: it is a hint to line up with, not the result.
    static let guideOutlineWidth: Float = 0.0015
    /// The EOT samples' guide yellow, sRGB (1, 0.84, 0), as the linear value the shader writes.
    static let guideColor = SIMD3<Float>(1, 0.673, 0)
    /// Least time between two confidence read-outs, so SwiftUI is not redrawn on every frame.
    static let statusInterval: CFTimeInterval = 0.25
    /// The guide follows the LiDAR distance only when it moves by at least this much, so depth
    /// noise does not make the outline breathe.
    static let autoDistanceStepCm = 2.0
    /// Half the side of the depth-map window measured under the guide, in depth pixels (7 x 7).
    static let depthWindowRadius = 3

    let arView: ARView
    let depthSupported: Bool
    let guideViews: [EdgeGuideView]
    let canStartAutomatically: Bool

    @Published private(set) var phase: EdgeTrackingPhase
    @Published private(set) var outline: OutlineShape = .segments([])
    @Published private(set) var statusLine = ""
    @Published var guideDistanceCm: Double {
        didSet { update { $0.guideDistance = Float(guideDistanceCm / 100) } }
    }
    @Published private(set) var guideViewIndex = -1
    /// Pass LiDAR depth to the tracker. The session records depth whenever the phone has LiDAR, for
    /// sizing the guide, so switching this only reloads the tracker.
    @Published var wantDepth: Bool {
        didSet {
            update { $0.wantDepth = wantDepth }
            wantTracking = false
        }
    }
    /// The guide distance follows the LiDAR distance to whatever is under the guide. Moving the
    /// slider by hand turns it off.
    @Published var autoDistance: Bool {
        didSet { update { $0.autoDistance = autoDistance } }
    }
    @Published var wantTracking = false {
        didSet { update { $0.wantTracking = wantTracking } }
    }
    /// The server finds the object; off while the user lines up a guide by hand.
    @Published private(set) var startsAutomatically: Bool
    /// The server has not found the object in several pictures in a row.
    @Published private(set) var searchStruggling = false

    var guideTitle: String { EdgeGuideView.label(index: guideViewIndex, in: guideViews) }

    private struct Controls {
        var guideViewIndex = -1
        var wantTracking = false
        var wantDepth = false
        var autoDistance = false
        var guideDistance: Float = 0.4
        var guideYaw: Float = 0.4
        var guidePitch: Float = 0.7
        var viewportSize = CGSize.zero
        var meshOutlineReady = false
        var startsAutomatically = false
    }

    private enum SearchResult {
        case found(simd_float4x4)
        case notFound
        case failed(String)
        case unauthorized
    }

    private let object: EdgeObject
    private let model: EdgeObjectModel
    private let bundle: URL
    private let cacheDirectory: URL
    private let meshURL: URL?
    private let outlineAnchor = AnchorEntity(world: .zero)
    private let trackedObject = Entity()
    private var meshRenderer: EdgeOutlineRenderer?
    private var guideRenderer: EdgeOutlineRenderer?
    private let guideObject = Entity()
    /// The guide's pose relative to the camera, in tracker axes; nil while the object is tracked.
    private var guideShown: [Float]?
    private var guideUpdates: Cancellable?
    private var meshOutlineReady = false
    private let delegateQueue = DispatchQueue(label: "ai.multiset.demo.edge-tracking.ar")
    private let searchQueue = DispatchQueue(label: "ai.multiset.demo.edge-tracking.search", qos: .userInitiated)
    private let api: EdgeObjectAPI
    private let lock = NSCondition()
    private var controls = Controls()
    private var pendingFrame: ARFrame?
    private var running = false
    private var loaded: (key: String, tracker: EotTracker, outline: ModelOutline)?
    private var loadFailure: (key: String, message: String)?
    /// Bumped whenever the way tracking starts changes, so an answer to an older picture is dropped.
    private var searchGeneration = 0
    private var searchInFlight = false
    private var searchResult: SearchResult?
    /// Counts AR session interruptions, after which ARKit starts a new world frame.
    private var interruptions = 0
    private let haptics = UINotificationFeedbackGenerator()

    init(object: EdgeObject, model: EdgeObjectModel, bundle: URL, cacheDirectory: URL, meshURL: URL?, api: EdgeObjectAPI) {
        self.object = object
        self.api = api
        self.model = model
        self.bundle = bundle
        self.cacheDirectory = cacheDirectory
        self.meshURL = meshURL
        guideViews = object.guideViews
        canStartAutomatically = object.startsAutomatically
        _startsAutomatically = Published(initialValue: object.startsAutomatically)
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        depthSupported = lidar
        _wantDepth = Published(initialValue: lidar)
        _autoDistance = Published(initialValue: lidar)
        phase = .loading("Preparing \(object.displayName)…")
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableHDR,
                                .disableAREnvironmentLighting, .disablePersonOcclusion, .disableGroundingShadows]
        guideDistanceCm = Self.clampedCm(Double(model.modelDistance * 100))
        super.init()
        controls.guideDistance = Float(guideDistanceCm / 100)
        controls.wantDepth = lidar
        controls.autoDistance = lidar
        controls.startsAutomatically = object.startsAutomatically
        arView.session.delegate = self
        arView.session.delegateQueue = delegateQueue
        trackedObject.isEnabled = false
        outlineAnchor.addChild(trackedObject)
        guideObject.isEnabled = false
        outlineAnchor.addChild(guideObject)
        arView.scene.addAnchor(outlineAnchor)
        // The guide is fixed to the screen, so it is re-placed with the camera of every rendered frame.
        guideUpdates = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.placeGuide() }
        setGuideView(guideViews.isEmpty ? -1 : 0)
    }

    deinit {
        guideUpdates?.cancel()
    }

    func start() {
        lock.lock()
        let alreadyRunning = running
        running = true
        lock.unlock()
        guard !alreadyRunning else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        EotThread.start("eot-ar") { [weak self] in self?.workLoop() }
        runSession()
        loadMeshOutline()
    }

    /// The Object Tracking flow's outline, built from the object's GLB. GLB and tracker share the
    /// object's coordinates, so the tracked pose places it without any axis conversion.
    private func loadMeshOutline() {
        guard let meshURL, meshRenderer == nil else { return }
        let renderer = EdgeOutlineRenderer(outlineWidth: Self.outlineWidth)
        let guide = EdgeOutlineRenderer(outlineWidth: Self.guideOutlineWidth, color: Self.guideColor)
        meshRenderer = renderer
        guideRenderer = guide
        let code = object.objectCode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: meshURL) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let asset = ObjectMeshAsset(objectCode: code, glbData: data, cacheURL: meshURL)
                renderer.renderOutlineMesh(meshResult: asset, parentEntity: self.trackedObject)
                guide.renderOutlineMesh(meshResult: asset, parentEntity: self.guideObject)
            }
            #if DEBUG
            Self.logMeshAlignment(glb: data, trackerMesh: self?.model.meshURL)
            #endif
        }
    }

    /// Main thread: the 2D outline steps aside once both mesh outlines are in the scene.
    private func checkMeshOutlines() {
        guard !meshOutlineReady, meshRenderer?.hasMesh() == true, guideRenderer?.hasMesh() == true else { return }
        meshOutlineReady = true
        update { $0.meshOutlineReady = true }
    }

    /// Every rendered frame: holds the guide in front of the camera that frame is drawn with.
    private func placeGuide() {
        checkMeshOutlines()
        guard meshOutlineReady, let pose = guideShown, let camera = arView.session.currentFrame?.camera else {
            guideObject.isEnabled = false
            return
        }
        guideObject.transform = Transform(matrix: PoseMath.worldTransform(trackerPose: pose, cameraTransform: camera.transform))
        guideObject.isEnabled = true
    }

    /// Main thread: places the outline at the steadied pose, or hides it while there is none.
    private func showTrackedObject(_ transform: simd_float4x4?) {
        checkMeshOutlines()
        guard let transform, meshOutlineReady else {
            trackedObject.isEnabled = false
            return
        }
        trackedObject.transform = Transform(matrix: transform)
        trackedObject.isEnabled = true
    }

    func stop() {
        arView.session.pause()
        lock.lock()
        running = false
        pendingFrame = nil
        lock.broadcast()
        lock.unlock()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func setViewportSize(_ size: CGSize) {
        update { $0.viewportSize = size }
    }

    func nextGuideView() {
        guard !guideViews.isEmpty else { return }
        setGuideView(guideViewIndex + 1 >= guideViews.count ? -1 : guideViewIndex + 1)
    }

    func previousGuideView() {
        guard !guideViews.isEmpty else { return }
        setGuideView(guideViewIndex < 0 ? guideViews.count - 1 : guideViewIndex - 1)
    }

    /// Leaves the server search for the guide, for when the object is not found.
    func alignManually() {
        setStartsAutomatically(false)
    }

    func findAutomatically() {
        guard canStartAutomatically else { return }
        setStartsAutomatically(true)
    }

    private func setStartsAutomatically(_ automatic: Bool) {
        startsAutomatically = automatic
        wantTracking = false
        update {
            $0.startsAutomatically = automatic
            searchGeneration += 1
            searchResult = nil
        }
    }

    /// Turns the free guide by a drag on the picture, in points.
    func turnGuide(dx: CGFloat, dy: CGFloat) {
        guard !wantTracking, !startsAutomatically else { return }
        update {
            $0.guideYaw += Float(dx) * 0.012
            $0.guidePitch += Float(dy) * 0.012
        }
    }

    private func setGuideView(_ index: Int) {
        guideViewIndex = index
        wantTracking = false
        update { $0.guideViewIndex = index }
        // The slider starts at the distance the view or the model was made for; the user moves it
        // to wherever they stand, since a start outline of the wrong size is not recovered from.
        let metres = index >= 0 && index < guideViews.count
            ? PoseMath.distance(guideViews[index].pose) : model.modelDistance
        guideDistanceCm = Self.clampedCm(Double(metres * 100).rounded())
    }

    private static func clampedCm(_ cm: Double) -> Double {
        min(maxGuideCm, max(minGuideCm, cm))
    }

    private func runSession() {
        #if !targetEnvironment(simulator)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = []
        configuration.isLightEstimationEnabled = false
        configuration.isAutoFocusEnabled = true
        // 4:3 like the tracker's 640x480; 30 fps leaves room for the tracker on every frame.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let format = formats.first(where: { $0.imageResolution == CGSize(width: 1920, height: 1440) && $0.framesPerSecond == 30 })
            ?? formats.first(where: { $0.imageResolution == CGSize(width: 1920, height: 1440) }) {
            configuration.videoFormat = format
        }
        if depthSupported { configuration.frameSemantics.insert(.sceneDepth) }
        arView.session.run(configuration)
        #endif
    }

    private func update(_ change: (inout Controls) -> Void) {
        lock.lock()
        change(&controls)
        lock.unlock()
    }

    private func post(_ change: @escaping (EdgeTrackingSession) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { change(self) }
        }
    }

    private func publish(phase newPhase: EdgeTrackingPhase, outline newOutline: OutlineShape, status: String) {
        post { session in
            session.signalTransition(from: session.phase, to: newPhase)
            session.phase = newPhase
            session.outline = newOutline
            session.statusLine = status
        }
    }

    private func signalTransition(from old: EdgeTrackingPhase, to new: EdgeTrackingPhase) {
        guard case .tracking(_, let lostNow) = new, !lostNow else { return }
        switch old {
        case .tracking(_, let wasLost) where wasLost: haptics.notificationOccurred(.success)
        case .aligning, .searching: haptics.notificationOccurred(.success)
        default: break
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Keep only the newest frame: frames that arrive while the tracker is busy are dropped,
        // so ARKit never waits on frames this screen still holds.
        lock.lock()
        pendingFrame = frame
        lock.signal()
        lock.unlock()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // An answer to a picture taken before the break is in a world frame that may no longer hold.
        lock.lock()
        searchGeneration += 1
        searchResult = nil
        interruptions += 1
        lock.unlock()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = "AR session failed: \(error.localizedDescription)"
        post { $0.phase = .failed(message) }
    }

    // MARK: Worker thread

    private struct WorkerState {
        var tracker: EotTracker?
        var outline: ModelOutline?
        var trackerKey = ""
        var loadingKey = ""
        var converter: CameraImageConverter?
        var pose = [Float](repeating: 0, count: 16)
        var confidence: Float = -1
        var lost = false
        var wasTracking = false
        /// The guide tracking started from: without ARKit's camera pose the library holds a lost
        /// object's pose there and resumes once the object is back inside it.
        var startGuide = [Float](repeating: 0, count: 16)
        var smoother = PoseSmoother()
        var postedGuide: [Float]?
        var publishedKind = ""
        var publishedStatus = ""
        var publishedOutline: OutlineShape?
        var publishedAt: CFTimeInterval = 0
        var schedule = EdgeSearchSchedule()
        var postedStruggling = false
        var lastCamera: (transform: simd_float4x4, time: TimeInterval)?
        var searchCount = 0
        var interruptionsSeen = 0
        /// False from an interruption (a new ARKit world) until a start re-anchors the tracker.
        var cameraPoseHolds = true
        var searchNote = ""
        var sessionExpired = false
    }

    private func workLoop() {
        var state = WorkerState()
        while true {
            lock.lock()
            while running && pendingFrame == nil { lock.wait() }
            guard running, let frame = pendingFrame else {
                lock.unlock()
                break
            }
            pendingFrame = nil
            let c = controls
            let newlyLoaded = loaded
            loaded = nil
            let failure = loadFailure
            let result = searchResult
            searchResult = nil
            let interruptionCount = interruptions
            lock.unlock()

            if interruptionCount != state.interruptionsSeen {
                state.interruptionsSeen = interruptionCount
                state.cameraPoseHolds = false
                state.lastCamera = nil
            }

            if let newlyLoaded, newlyLoaded.key == state.loadingKey {
                state.tracker = newlyLoaded.tracker
                state.outline = newlyLoaded.outline
                state.trackerKey = newlyLoaded.key
                state.loadingKey = ""
            }
            autoreleasepool { process(frame, c, failure, result, &state) }
        }
        // The tracker is destroyed here, on the thread with the large stack.
        state.tracker = nil
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    private func process(_ frame: ARFrame, _ c: Controls, _ failure: (key: String, message: String)?,
                         _ result: SearchResult?, _ state: inout WorkerState) {
        let captured = frame.capturedImage
        if state.converter?.matches(captured) != true {
            state.converter = CameraImageConverter(sourceWidth: CVPixelBufferGetWidth(captured),
                                                   sourceHeight: CVPixelBufferGetHeight(captured))
        }
        guard let converter = state.converter, converter.convert(captured) else {
            publish(phase: .failed("The camera image is not in a supported format."), outline: .segments([]), status: "")
            return
        }
        let w = converter.width, h = converter.height
        let k = frame.camera.intrinsics
        let intrinsics = ScaledIntrinsics(fu: k[0][0], fv: k[1][1], ppu: k[2][0], ppv: k[2][1], factor: 1 / converter.scale)

        let useDepth = c.wantDepth && depthSupported
        let depthMap = useDepth ? frame.sceneDepth?.depthMap : nil
        var note = ""
        var loadError: String?
        if useDepth && depthMap == nil {
            note = "Waiting for LiDAR depth…"
        } else {
            let depthSize = depthMap.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "nodepth"
            let key = "\(w)x\(h)|\(depthSize)"
            if key != state.trackerKey {
                if let failure, failure.key == key {
                    loadError = failure.message
                } else if state.loadingKey != key {
                    state.tracker = nil
                    state.outline = nil
                    state.trackerKey = ""
                    state.loadingKey = key
                    load(key: key, width: w, height: h, intrinsics: intrinsics, depthMap: depthMap,
                         fullIntrinsics: k, capturedWidth: Float(CVPixelBufferGetWidth(captured)))
                }
            }
        }

        let centre = (model.boundsMin + model.boundsMax) / 2
        let viewport = c.viewportSize
        let mapper = OutlineViewMapper(imageSize: CGSize(width: w, height: h),
                                       displayTransform: frame.displayTransform(for: .portrait, viewportSize: viewport),
                                       viewportSize: viewport)
        func screenPoint(_ pose: [Float]) -> CGPoint? {
            let p = PoseMath.transform(pose, centre.x, centre.y, centre.z)
            guard p.z > 0.01 else { return nil }
            return mapper.map(CGPoint(x: CGFloat(intrinsics.fu * p.x / p.z + intrinsics.ppu),
                                      y: CGFloat(intrinsics.fv * p.y / p.z + intrinsics.ppv)))
        }
        func isOnScreen(_ pose: [Float]) -> Bool {
            guard viewport.width > 0, viewport.height > 0 else { return true }
            guard let point = screenPoint(pose) else { return false }
            return point.x >= 0 && point.x <= viewport.width && point.y >= 0 && point.y <= viewport.height
        }

        let guide: [Float]
        if c.guideViewIndex >= 0, c.guideViewIndex < guideViews.count {
            guide = PoseMath.moved(PoseMath.guidePose(fromView: guideViews[c.guideViewIndex].pose), toDistance: c.guideDistance)
        } else {
            guide = PoseMath.guidePose(yaw: c.guideYaw, pitch: c.guidePitch, distance: c.guideDistance)
        }

        if c.autoDistance && !c.wantTracking && !c.startsAutomatically, let metres = measureGuideDistance(frame, guide: guide) {
            let cm = Self.clampedCm(Double(metres * 100).rounded())
            if abs(cm - Double(c.guideDistance * 100)) >= Self.autoDistanceStepCm {
                post { if $0.autoDistance && !$0.wantTracking { $0.guideDistanceCm = cm } }
            }
        }

        let color = EotImage(pixels: UnsafeRawPointer(converter.rgba), rowBytes: converter.rgbaRowBytes)
        if let depthMap { CVPixelBufferLockBaseAddress(depthMap, .readOnly) }
        defer { if let depthMap { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) } }
        var depthImage: EotImage?
        if let depthMap, CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
           let base = CVPixelBufferGetBaseAddress(depthMap) {
            depthImage = EotImage(pixels: UnsafeRawPointer(base), rowBytes: CVPixelBufferGetBytesPerRow(depthMap))
        }

        let now = CACurrentMediaTime()
        var worldSteady = false
        if case .normal = frame.camera.trackingState { worldSteady = true }
        // ARKit's pose is handed on only while its tracking is normal; the tracker copes without it.
        let cameraPose = worldSteady ? PoseMath.trackerCamera(frame.camera.transform) : nil
        let turnRate = state.lastCamera.map {
            EdgeSearchPolicy.turnRate(from: $0.transform, to: frame.camera.transform, seconds: frame.timestamp - $0.time)
        } ?? 0
        state.lastCamera = (frame.camera.transform, frame.timestamp)
        if !c.startsAutomatically { state.schedule = EdgeSearchSchedule() }

        var tracking = false
        var stopped: String?
        var found: [Float]?
        switch result {
        case .found(let world):
            state.searchNote = ""
            // Moving the server's world pose into this frame needs ARKit's world to have held since.
            if worldSteady {
                let pose = PoseMath.trackerPose(world: world, cameraTransform: frame.camera.transform)
                if EdgeSearchPolicy.isInView(pose, boundsMin: model.boundsMin, boundsMax: model.boundsMax,
                                             intrinsics: intrinsics, width: w, height: h) {
                    found = pose
                    state.schedule.answered(.found, at: now)
                } else {
                    state.schedule.answered(.notFound, at: now)
                }
            }
        case .notFound:
            state.searchNote = ""
            state.schedule.answered(.notFound, at: now)
        case .failed(let message):
            state.searchNote = message
            state.schedule.answered(.failed, at: now)
        case .unauthorized:
            state.sessionExpired = true
        case nil:
            break
        }
        var holdSteady = false
        var onScreen = true
        if let tracker = state.tracker {
            let canStep = !tracker.usesDepth || depthImage != nil
            do {
                if !c.wantTracking && tracker.isTracking { tracker.stop() }
                let trackHolds = tracker.isTracking && !tracker.isLost
                if c.startsAutomatically, let found, trackHolds, EdgeSearchPolicy.agrees(found, tracker.pose()) {
                    state.schedule.confirmed(at: now)
                } else if c.startsAutomatically, let found, canStep, !trackHolds || state.schedule.needsServer {
                    // A found pose replaces a lost or long-weak track, never a good one the library recovered.
                    tracker.stop()
                    try tracker.setPose(found)
                    state.startGuide = found
                    if let cameraPose { tracker.setCameraPose(cameraPose) }
                    try tracker.start(color: color, format: .rgba, depth: depthImage, depthFormat: .f32)
                    state.cameraPoseHolds = true
                    state.schedule.started()
                    update { $0.wantTracking = true }
                    post { $0.wantTracking = true }
                } else if c.wantTracking && !c.startsAutomatically && !tracker.isTracking && canStep {
                    try tracker.setPose(guide)
                    state.startGuide = guide
                    if let cameraPose { tracker.setCameraPose(cameraPose) }
                    try tracker.start(color: color, format: .rgba, depth: depthImage, depthFormat: .f32)
                    state.cameraPoseHolds = true
                }
                tracking = tracker.isTracking
                if tracking && canStep {
                    if let cameraPose, state.cameraPoseHolds { tracker.setCameraPose(cameraPose) }
                    try tracker.step(color: color, format: .rgba, depth: depthImage, depthFormat: .f32)
                }
            } catch {
                tracker.stop()
                tracking = false
                stopped = "Tracking stopped: \(error.localizedDescription)"
                print("EdgeObjectTracking >> tracker error: \(error.localizedDescription)")
            }
            if tracking {
                state.pose = tracker.pose()
                state.confidence = tracker.confidence
                state.lost = tracker.isLost
                onScreen = isOnScreen(state.pose)
            } else {
                state.confidence = -1
                state.lost = false
            }
            state.schedule.observe(tracking: tracking, lost: state.lost, onScreen: onScreen, confidence: state.confidence, at: now)
            if c.startsAutomatically && !state.sessionExpired && worldSteady
                && state.schedule.needsServer && state.schedule.isDue(at: now) {
                if turnRate > EdgeSearchPolicy.maxTurnRate {
                    holdSteady = true
                } else {
                    let box = queryBox(frame, viewport: c.viewportSize, trackedPose: state.schedule.boxesTheTrack ? state.pose : nil,
                                       intrinsics: intrinsics, width: w, height: h)
                    state.searchCount += 1
                    if search(frame, box: box, frameId: "edge-\(state.searchCount)") {
                        state.schedule.sent(at: now)
                    }
                }
            }
        }
        if state.schedule.isStruggling != state.postedStruggling {
            let struggling = state.schedule.isStruggling
            state.postedStruggling = struggling
            post { $0.searchStruggling = struggling }
        }

        var shown: simd_float4x4?
        if tracking && !state.lost {
            let world = PoseMath.worldTransform(trackerPose: state.pose, cameraTransform: frame.camera.transform)
            shown = state.smoother.update(world: world, time: frame.timestamp)
        } else {
            state.smoother.reset()
        }
        if tracking || state.wasTracking {
            DispatchQueue.main.async { [weak self] in self?.showTrackedObject(shown) }
        }
        state.wasTracking = tracking

        // The guide shows while aligning and, while lost, where the library looks: with ARKit's camera
        // pose, the held pose where the object was last tracked in the room, otherwise the start
        // guide. Auto start has none: the box is shown instead and the server finds the object again.
        let lostOutline = cameraPose != nil && state.cameraPoseHolds ? state.pose : state.startGuide
        let guideToShow: [Float]? = c.startsAutomatically ? nil : (!tracking ? guide : (state.lost ? lostOutline : nil))
        if guideToShow != state.postedGuide {
            state.postedGuide = guideToShow
            DispatchQueue.main.async { [weak self] in self?.guideShown = guideToShow }
        }

        let drawnPose: [Float]?
        if c.meshOutlineReady {
            drawnPose = nil
        } else if let guideToShow {
            drawnPose = guideToShow
        } else if tracking {
            drawnPose = shown.map { PoseMath.trackerPose(world: $0, cameraTransform: frame.camera.transform) } ?? state.pose
        } else {
            drawnPose = nil
        }
        let shape: OutlineShape
        if let drawnPose {
            let mapper = OutlineViewMapper(imageSize: CGSize(width: w, height: h),
                                           displayTransform: frame.displayTransform(for: .portrait, viewportSize: c.viewportSize),
                                           viewportSize: c.viewportSize)
            shape = state.outline.map { mapper.map($0.shape(pose: drawnPose, intrinsics: intrinsics)) } ?? .segments([])
        } else {
            shape = .segments([])
        }

        let newPhase: EdgeTrackingPhase
        let status: String
        if let loadError {
            newPhase = .failed(loadError)
            status = loadError
        } else if state.sessionExpired {
            newPhase = .failed(EdgeObjectAPIError.unauthorized.localizedDescription)
            status = EdgeObjectAPIError.unauthorized.localizedDescription
        } else if state.tracker == nil {
            newPhase = .loading("Preparing \(object.displayName)…")
            status = note.isEmpty ? "Preparing \(object.displayName)…" : note
        } else if tracking {
            newPhase = .tracking(confidence: state.confidence, lost: state.lost)
            if state.lost && c.startsAutomatically {
                status = "Lost: fit the whole object inside the box"
            } else if state.lost {
                status = "Lost: put the object back inside the yellow outline"
            } else if state.confidence >= 0 {
                status = "Tracking · \(Int((state.confidence * 100).rounded())) %"
            } else {
                status = "Tracking"
            }
        } else if c.startsAutomatically {
            newPhase = .searching
            if let stopped {
                status = stopped
            } else if !note.isEmpty {
                status = note
            } else if holdSteady {
                status = "Hold the phone steady"
            } else if !state.searchNote.isEmpty {
                status = state.searchNote
            } else {
                status = "Looking for \(object.displayName)…"
            }
        } else {
            newPhase = .aligning
            let hint: String
            if c.guideViewIndex < 0 {
                hint = "Drag to turn the yellow outline, then line it up"
            } else if c.autoDistance {
                hint = "Line up the yellow outline with the object"
            } else {
                hint = "Match the yellow outline's size and line it up"
            }
            status = stopped ?? (note.isEmpty ? hint : note)
        }
        if let stopped {
            post { $0.wantTracking = false; $0.statusLine = stopped }
        }
        let kind: String
        switch newPhase {
        case .loading: kind = "loading"
        case .searching: kind = "searching"
        case .aligning: kind = "aligning"
        case .tracking(_, let lost): kind = lost ? "lost" : "tracking"
        case .failed: kind = "failed"
        }
        let statusDue = status != state.publishedStatus && now - state.publishedAt >= Self.statusInterval
        if kind != state.publishedKind || shape != state.publishedOutline || statusDue {
            state.publishedKind = kind
            state.publishedStatus = status
            state.publishedOutline = shape
            state.publishedAt = now
            publish(phase: newPhase, outline: shape, status: status)
        }
    }

    /// The box sent with a search: around the object where a weak track puts it, otherwise the box
    /// on screen.
    private func queryBox(_ frame: ARFrame, viewport: CGSize, trackedPose: [Float]?,
                          intrinsics: ScaledIntrinsics, width: Int, height: Int) -> EdgeQueryBox? {
        if let trackedPose, let box = EdgeQueryBox(trackerPose: trackedPose, boundsMin: model.boundsMin, boundsMax: model.boundsMax,
                                                   intrinsics: intrinsics, imageWidth: width, imageHeight: height) {
            return box
        }
        guard let rect = EdgeQueryBox.screenRect(viewport: viewport) else { return nil }
        return EdgeQueryBox(screenRect: rect, viewport: viewport,
                            displayTransform: frame.displayTransform(for: .portrait, viewportSize: viewport))
    }

    /// Sends this frame to the server to find the object, unless a request is already out. The
    /// answer is a world pose, so it still fits when the phone has moved while it was on its way.
    private func search(_ frame: ARFrame, box: EdgeQueryBox?, frameId: String) -> Bool {
        lock.lock()
        guard !searchInFlight else {
            lock.unlock()
            return false
        }
        searchInFlight = true
        let generation = searchGeneration
        lock.unlock()
        let pixelBuffer = frame.capturedImage, intrinsics = frame.camera.intrinsics, camera = frame.camera.transform
        let api = api, code = object.objectCode
        searchQueue.async { [weak self] in
            guard let query = EdgeStartQuery.prepare(pixelBuffer: pixelBuffer, intrinsics: intrinsics, cameraTransform: camera,
                                                     box: box, frameId: frameId) else {
                self?.finishSearch(.failed("The camera picture could not be encoded"), generation: generation)
                return
            }
            Task {
                let result: SearchResult?
                do {
                    let answer = try await api.startPose(code: code, frame: query)
                    if !answer.answers(query) {
                        result = nil
                    } else if let world = answer.worldPose(queryCamera: query.queryCamera),
                              EdgeSearchPolicy.accepts(confidence: answer.confidence) {
                        result = .found(world)
                    } else {
                        result = .notFound
                    }
                } catch EdgeObjectAPIError.unauthorized {
                    result = .unauthorized
                } catch {
                    result = .failed("Can't reach the server, trying again: \(error.localizedDescription)")
                }
                self?.finishSearch(result, generation: generation)
            }
        }
        return true
    }

    private func finishSearch(_ result: SearchResult?, generation: Int) {
        lock.lock()
        searchInFlight = false
        if running && generation == searchGeneration && controls.startsAutomatically { searchResult = result }
        lock.unlock()
    }

    /// The guide distance that puts the model's front on the LiDAR depth under the guide's origin;
    /// nil without depth, or where too little of the window has a confident measurement.
    private func measureGuideDistance(_ frame: ARFrame, guide: [Float]) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
        let k = frame.camera.intrinsics
        let intrinsics = ScaledIntrinsics(fu: k[0][0], fv: k[1][1], ppu: k[2][0], ppv: k[2][1],
                                          factor: Float(width) / Float(CVPixelBufferGetWidth(frame.capturedImage)))
        guard let pixel = GuideSizing.originPixel(guidePose: guide, intrinsics: intrinsics) else { return nil }
        let x = Int(pixel.x.rounded()), y = Int(pixel.y.rounded())
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let confidenceMap = sceneDepth.confidenceMap
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let surface = GuideSizing.medianDepth(at: x, y, radius: Self.depthWindowRadius, width: width, height: height) { xx, yy in
            if let confidenceBase,
               confidenceBase.load(fromByteOffset: yy * confidenceRow + xx, as: UInt8.self) < UInt8(ARConfidenceLevel.medium.rawValue) {
                return nil
            }
            return depthBase.load(fromByteOffset: yy * depthRow + xx * MemoryLayout<Float32>.size, as: Float32.self)
        }
        return surface.map { GuideSizing.distance(surfaceDepth: $0, guidePose: guide, boundsMin: model.boundsMin, boundsMax: model.boundsMax) }
    }

    private func load(key: String, width: Int, height: Int, intrinsics: ScaledIntrinsics, depthMap: CVPixelBuffer?,
                      fullIntrinsics k: simd_float3x3, capturedWidth: Float) {
        let depthWidth = depthMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let depthHeight = depthMap.map { CVPixelBufferGetHeight($0) } ?? 0
        let bundle = bundle, cacheDirectory = cacheDirectory, meshURL = model.meshURL, name = object.displayName
        EotThread.start("eot-load") { [weak self] in
            let started = CACurrentMediaTime()
            do {
                let tracker = try EotTracker()
                try tracker.setOption("snap_start", "1")    // a rough aim at the object is enough
                try tracker.setOption("auto_recover", "1")  // resume when a lost object is back in view
                // The EOT samples' value (EOT 29a86e0): at the library's 0.55, poses half on a hand-turned
                // object passed as tracked for hundreds of frames; 0.75 raised too many false alarms.
                try tracker.setOption("lost_ratio", "0.7")
                try tracker.setColorIntrinsics(fu: intrinsics.fu, fv: intrinsics.fv, ppu: intrinsics.ppu, ppv: intrinsics.ppv,
                                               width: width, height: height)
                if depthWidth > 0 {
                    // The depth map covers the captured image's view at a lower resolution.
                    let depthIntrinsics = ScaledIntrinsics(fu: k[0][0], fv: k[1][1], ppu: k[2][0], ppv: k[2][1],
                                                           factor: Float(depthWidth) / capturedWidth)
                    try tracker.setDepthIntrinsics(fu: depthIntrinsics.fu, fv: depthIntrinsics.fv,
                                                   ppu: depthIntrinsics.ppu, ppv: depthIntrinsics.ppv,
                                                   width: depthWidth, height: depthHeight, depthScale: 1)
                }
                try tracker.loadBundle(bundle, cacheDirectory: cacheDirectory)
                let outline = try ModelOutline(obj: meshURL)
                print(String(format: "EdgeObjectTracking >> loaded %@ in %.0f ms; image %dx%d; depth %@", name,
                             (CACurrentMediaTime() - started) * 1000, width, height,
                             depthWidth > 0 ? "\(depthWidth)x\(depthHeight)" : "off"))
                guard let self else { return }
                self.lock.lock()
                // A screen that closed while loading drops the tracker here, on this thread's stack.
                if self.running { self.loaded = (key, tracker, outline) }
                self.lock.unlock()
            } catch {
                print("EdgeObjectTracking >> loading \(name) failed: \(error.localizedDescription)")
                guard let self else { return }
                self.lock.lock()
                self.loadFailure = (key, "Loading \(name) failed: \(error.localizedDescription)")
                self.lock.unlock()
            }
        }
    }
}

#if DEBUG
extension EdgeTrackingSession {
    /// The tracked outline is drawn from the GLB, the tracker works from its own OBJ; both should
    /// span the same box. A mismatch here means the outline will sit off the object.
    static func logMeshAlignment(glb: Data, trackerMesh: URL?) {
        guard let trackerMesh, let obj = try? ObjMesh(url: trackerMesh),
              let nodes = try? GLBParser.parse(glb, preparing: { $0.positions }) else { return }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        func walk(_ node: GLBNode<[SIMD3<Float>]>, _ parent: simd_float4x4) {
            let matrix = parent * node.transform.matrix
            for positions in node.primitives {
                for p in positions {
                    let q = matrix * SIMD4(p, 1)
                    lo = simd_min(lo, SIMD3(q.x, q.y, q.z))
                    hi = simd_max(hi, SIMD3(q.x, q.y, q.z))
                }
            }
            node.children.forEach { walk($0, matrix) }
        }
        nodes.forEach { walk($0, matrix_identity_float4x4) }
        var objLo = obj.vertices.first ?? .zero, objHi = objLo
        for v in obj.vertices {
            objLo = simd_min(objLo, v)
            objHi = simd_max(objHi, v)
        }
        func mm(_ v: SIMD3<Float>) -> String { String(format: "(%.0f, %.0f, %.0f)", v.x * 1000, v.y * 1000, v.z * 1000) }
        print("EdgeObjectTracking >> mesh check: GLB centre \(mm((lo + hi) / 2)) size \(mm(hi - lo)) mm; "
              + "tracker model centre \(mm((objLo + objHi) / 2)) size \(mm(objHi - objLo)) mm")
    }
}
#endif
