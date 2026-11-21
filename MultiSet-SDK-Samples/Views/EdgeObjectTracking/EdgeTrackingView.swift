/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import SwiftUI
import RealityKit
import MultiSetSDK

/// Full-screen camera with the object's outline: line it up, start, and watch it track.
struct EdgeTrackingView: View {
    let object: EdgeObject
    @StateObject private var session: EdgeTrackingSession
    @Environment(\.dismiss) private var dismiss
    @State private var cameraDenied = false
    @State private var lastDrag = CGSize.zero

    init(object: EdgeObject, model: EdgeObjectModel, storage: EdgeObjectStorage) {
        self.object = object
        let id = object.id ?? object.objectCode
        let mesh = storage.meshURL(objectId: id)
        _session = StateObject(wrappedValue: EdgeTrackingSession(
            object: object, model: model,
            bundle: storage.bundleURL(objectId: id), cacheDirectory: storage.cacheDirectory(objectId: id),
            meshURL: FileManager.default.fileExists(atPath: mesh.path) ? mesh : nil,
            api: EdgeObjectAPI(baseURL: MultiSet.shared.activeBaseURL, token: { MultiSet.shared.authToken })))
    }

    var body: some View {
        ZStack {
            if EotTracker.isSupported && !cameraDenied {
                GeometryReader { geometry in
                    EdgeCameraView(session: session)
                        .onAppear { session.setViewportSize(geometry.size) }
                        .onChange(of: geometry.size) { session.setViewportSize($0) }
                }
                .ignoresSafeArea()
                EdgeOutlineCanvas(shape: session.outline, phase: session.phase)
                    .ignoresSafeArea()
                if showsQueryBox {
                    GeometryReader { geometry in
                        QueryBoxOverlay(viewport: geometry.size, rect: EdgeQueryBox.screenRect(viewport: geometry.size))
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(turnGesture)
            } else {
                MSColor.stage.ignoresSafeArea()
            }

            VStack(spacing: MSSpacing.md) {
                Spacer()
                centreCard
                Spacer()
                if case .tracking(_, let lost) = session.phase, lost {
                    lostBanner
                }
                bottomPanel
            }
            .padding(.horizontal, MSSpacing.lg)
            .padding(.bottom, MSSpacing.lg)
        }
        .animation(.easeInOut(duration: 0.25), value: showsQueryBox)
        .navigationTitle(object.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { statePill }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            OrientationLock.shared.set(.portrait, preferred: .portrait)
            guard EotTracker.isSupported else { return }
            Task {
                if await EdgeCameraAccess.authorize() {
                    session.start()
                } else {
                    cameraDenied = true
                }
            }
        }
        .onDisappear {
            session.stop()
            OrientationLock.shared.restoreDefault()
        }
    }

    // MARK: Pieces

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                session.turnGuide(dx: value.translation.width - lastDrag.width,
                                  dy: value.translation.height - lastDrag.height)
                lastDrag = value.translation
            }
            .onEnded { _ in lastDrag = .zero }
    }

    /// Auto start shows the box the query sends while it looks for the object, and again while lost.
    private var showsQueryBox: Bool {
        guard session.startsAutomatically else { return false }
        switch session.phase {
        case .searching: return true
        case .tracking(_, let lost): return lost
        default: return false
        }
    }

    @ViewBuilder
    private var statePill: some View {
        switch session.phase {
        case .loading: cameraPill("Preparing", MSColor.AR.textDim)
        case .searching: cameraPill("Searching", MSColor.AR.accent)
        case .aligning: cameraPill("Aligning", EdgeOutlineCanvas.guideYellow)
        case .tracking(let confidence, let lost):
            if lost {
                cameraPill("Lost", MSColor.AR.bad)
            } else if confidence >= 0 {
                cameraPill("Tracking · \(Int((confidence * 100).rounded())) %", confidence < 0.75 ? MSColor.AR.poor : MSColor.AR.good)
            } else {
                cameraPill("Tracking", MSColor.AR.good)
            }
        case .failed: cameraPill("Failed", MSColor.AR.bad)
        }
    }

    private func cameraPill(_ text: String, _ colour: Color) -> some View {
        HStack(spacing: MSSpacing.xs) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text).font(MSFont.captionEmphasis).foregroundStyle(MSColor.AR.text).monospacedDigit()
        }
        .padding(.horizontal, MSSpacing.md)
        .padding(.vertical, MSSpacing.sm)
        .background(MSColor.AR.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(MSColor.AR.panelBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var centreCard: some View {
        if !EotTracker.isSupported {
            messageCard(symbol: "iphone.slash", title: "Edge tracking needs an iPhone",
                        message: "The tracker runs only on a device. Build and run the demo on an iPhone to try it.") {
                Button("Back") { dismiss() }.msGlassButton(fullWidth: true)
            }
        } else if cameraDenied {
            messageCard(symbol: "camera.fill", title: "Camera access is off",
                        message: "Edge tracking needs the camera. Allow it in Settings, then come back.") {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .msGlassButton(fullWidth: true)
            }
        } else {
            switch session.phase {
            case .loading(let text):
                VStack(spacing: MSSpacing.md) {
                    ProgressView().tint(MSColor.AR.text)
                    Text(text).font(MSFont.bodyEmphasis).foregroundStyle(MSColor.AR.text)
                    Text("The first open unpacks the model, which takes a few seconds.")
                        .font(MSFont.caption).foregroundStyle(MSColor.AR.textDim).multilineTextAlignment(.center)
                }
                .padding(MSSpacing.xl)
                .cameraPanel()
            case .failed(let message):
                messageCard(symbol: "exclamationmark.triangle.fill", title: "Tracking could not start", message: message) {
                    Button("Back") { dismiss() }.msGlassButton(fullWidth: true)
                }
            default:
                EmptyView()
            }
        }
    }

    private func messageCard<Action: View>(symbol: String, title: String, message: String,
                                           @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: MSSpacing.md) {
            Image(systemName: symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(MSColor.AR.accent)
            Text(title).font(MSFont.headline).foregroundStyle(MSColor.AR.text).multilineTextAlignment(.center)
            Text(message).font(MSFont.callout).foregroundStyle(MSColor.AR.textDim).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(MSSpacing.xl)
        .cameraPanel()
    }

    private var lostBanner: some View {
        HStack(spacing: MSSpacing.sm) {
            Image(systemName: "eye.slash.fill").foregroundStyle(MSColor.AR.bad)
            Text(session.startsAutomatically ? "Lost: fit the whole object inside the box" : "Lost: put the object back inside the yellow outline")
                .font(MSFont.captionEmphasis).foregroundStyle(MSColor.AR.text)
        }
        .padding(.horizontal, MSSpacing.lg)
        .padding(.vertical, MSSpacing.md)
        .background(MSColor.AR.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(MSColor.AR.bad.opacity(0.6), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch session.phase {
        case .searching:
            searchingPanel
        case .aligning, .loading:
            aligningPanel
        case .tracking:
            trackingPanel
        case .failed:
            EmptyView()
        }
    }

    private var aligningPanel: some View {
        VStack(alignment: .leading, spacing: MSSpacing.sm) {
            Text(session.statusLine.isEmpty ? "Line up the yellow outline with the object" : session.statusLine)
                .font(MSFont.callout).foregroundStyle(MSColor.AR.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MSSpacing.xs) {
                if !session.guideViews.isEmpty {
                    stepButton("chevron.left", "Previous guide view") { session.previousGuideView() }
                }
                Text(session.guideTitle)
                    .font(MSFont.captionEmphasis).foregroundStyle(MSColor.AR.textDim)
                    .lineLimit(1)
                if !session.guideViews.isEmpty {
                    stepButton("chevron.right", "Next guide view") { session.nextGuideView() }
                }
                Spacer(minLength: MSSpacing.sm)
                if session.depthSupported {
                    chip("LiDAR", systemImage: "dot.radiowaves.forward", isOn: session.wantDepth) {
                        session.wantDepth.toggle()
                    }
                    .accessibilityLabel("LiDAR depth for tracking")
                }
            }
            HStack(spacing: MSSpacing.sm) {
                Text("\(Int(session.guideDistanceCm)) cm")
                    .font(MSFont.mono).foregroundStyle(MSColor.AR.text).monospacedDigit()
                    .frame(width: 56, alignment: .leading)
                Slider(value: $session.guideDistanceCm, in: EdgeTrackingSession.minGuideCm...EdgeTrackingSession.maxGuideCm,
                       step: 1) { editing in
                    if editing { session.autoDistance = false }
                }
                .tint(EdgeOutlineCanvas.guideYellow)
                .accessibilityLabel("Guide distance")
                if session.depthSupported {
                    chip("Auto", systemImage: "scope", isOn: session.autoDistance) { session.autoDistance.toggle() }
                        .accessibilityLabel("Size the guide from LiDAR")
                }
            }
            HStack(spacing: MSSpacing.sm) {
                if session.canStartAutomatically {
                    Button {
                        session.findAutomatically()
                    } label: {
                        Image(systemName: "viewfinder")
                    }
                    .msGlassButton()
                    .accessibilityLabel("Find the object automatically")
                }
                Button("Start tracking") { session.wantTracking = true }
                    .msGlassButton(fullWidth: true)
                    .disabled(session.phase != .aligning)
            }
        }
        .padding(MSSpacing.md)
        .cameraPanel()
    }

    private var searchingPanel: some View {
        VStack(alignment: .leading, spacing: MSSpacing.sm) {
            HStack(spacing: MSSpacing.sm) {
                ProgressView().tint(MSColor.AR.accent)
                Text(session.statusLine.isEmpty ? "Looking for \(object.displayName)…" : session.statusLine)
                    .font(MSFont.callout).foregroundStyle(MSColor.AR.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if session.depthSupported {
                    chip("LiDAR", systemImage: "dot.radiowaves.forward", isOn: session.wantDepth) {
                        session.wantDepth.toggle()
                    }
                    .accessibilityLabel("LiDAR depth for tracking")
                }
            }
            if session.searchStruggling {
                Label("Still not found. Try from another side, in better light, or line it up by hand.",
                      systemImage: "lightbulb.fill")
                    .font(MSFont.caption).foregroundStyle(MSColor.AR.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                Text("Move closer or farther until it fills the box. Tracking starts by itself once it is found.")
                    .font(MSFont.caption).foregroundStyle(MSColor.AR.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(session.searchStruggling ? "Line it up by hand" : "Align manually") { session.alignManually() }
                .msGlassButton(fullWidth: true)
        }
        .padding(MSSpacing.md)
        .cameraPanel()
        .animation(.easeInOut(duration: 0.25), value: session.searchStruggling)
    }

    private var trackingPanel: some View {
        Button(session.startsAutomatically ? "Stop and search again" : "Stop and re-align") { session.wantTracking = false }
            .msGlassButton()
            .frame(maxWidth: .infinity)
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MSColor.AR.text)
                .frame(width: 32, height: MSSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private func chip(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(MSFont.captionEmphasis)
                .foregroundStyle(isOn ? MSColor.AR.text : MSColor.AR.textDim)
                .padding(.horizontal, MSSpacing.md)
                .frame(height: 30)
                .background(isOn ? MSColor.AR.accent.opacity(0.35) : Color.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? MSColor.AR.accent : MSColor.AR.panelBorder, lineWidth: 1))
                .frame(minHeight: MSSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private extension View {
    func cameraPanel() -> some View {
        frame(maxWidth: .infinity)
            .background(MSColor.AR.panel, in: RoundedRectangle(cornerRadius: MSRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MSRadius.lg, style: .continuous).strokeBorder(MSColor.AR.panelBorder, lineWidth: 1))
    }
}

/// The box the object query sends, with the area around it dimmed and its corners breathing.
private struct QueryBoxOverlay: View {
    let viewport: CGSize
    let rect: CGRect?
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cornerRadius: CGFloat = 14
    private static let cornerLength: CGFloat = 30

    var body: some View {
        if let rect {
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: viewport))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: Self.cornerRadius, height: Self.cornerRadius))
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(MSColor.AR.text.opacity(0.45), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Self.corners(in: rect)
                    .stroke(MSColor.AR.text, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .opacity(pulsing ? 1 : 0.6)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
                Label("Fit the whole object inside the box", systemImage: "viewfinder")
                    .font(MSFont.captionEmphasis).foregroundStyle(MSColor.AR.text)
                    .padding(.horizontal, MSSpacing.md)
                    .padding(.vertical, MSSpacing.sm)
                    .background(MSColor.AR.panel, in: Capsule())
                    .fixedSize()
                    .frame(width: rect.width)
                    .offset(x: rect.minX, y: rect.minY - 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { pulsing = true }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fit the whole object inside the box")
        }
    }

    private static func corners(in rect: CGRect) -> Path {
        let r = cornerRadius, l = cornerLength
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x, y: y + dy * l))
            path.addLine(to: CGPoint(x: x, y: y + dy * r))
            path.addQuadCurve(to: CGPoint(x: x + dx * r, y: y), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return path
    }
}

/// The session's own camera view; the SwiftUI layout around it reports the viewport size.
struct EdgeCameraView: UIViewRepresentable {
    let session: EdgeTrackingSession

    func makeUIView(context: Context) -> ARView { session.arView }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
