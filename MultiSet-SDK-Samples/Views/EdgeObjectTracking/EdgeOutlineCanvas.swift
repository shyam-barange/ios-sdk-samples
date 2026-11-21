/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import SwiftUI

/// The 2D outline, drawn only until the mesh outlines are ready or without the object's mesh: yellow
/// and dashed while the user lines it up or while the object is lost, otherwise solid in the colour
/// of how tracking is going.
struct EdgeOutlineCanvas: View {
    /// The EOT samples' guide yellow, as the mesh guide shows it.
    static let guideYellow = Color(red: 1, green: 0.84, blue: 0)

    let shape: OutlineShape
    let phase: EdgeTrackingPhase

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            let path = Self.path(for: shape)
            if let colour = trackingColour {
                context.stroke(path, with: .color(colour.opacity(0.3)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            } else {
                context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [6, 4]))
                context.stroke(path, with: .color(Self.guideYellow), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var trackingColour: Color? {
        guard case .tracking(let confidence, let lost) = phase else { return nil }
        if lost { return nil }
        if confidence >= 0 && confidence < 0.75 { return MSColor.AR.poor }
        return MSColor.AR.good
    }

    private static func path(for shape: OutlineShape) -> Path {
        var path = Path()
        switch shape {
        case .segments(let points):
            for i in stride(from: 0, to: points.count - 1, by: 2) {
                path.move(to: points[i])
                path.addLine(to: points[i + 1])
            }
        case .points(let points):
            // Dots drawn as short strokes, so the one stroke style serves both shapes.
            for p in points {
                path.move(to: CGPoint(x: p.x - 0.75, y: p.y))
                path.addLine(to: CGPoint(x: p.x + 0.75, y: p.y))
            }
        }
        return path
    }
}
