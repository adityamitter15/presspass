import SwiftUI

/// Draws joints and connecting bones from a `PoseFrame` over the camera
/// preview. `PoseFrame`'s coordinate space has y=0 at the bottom of the
/// image; SwiftUI's `Canvas` has y=0 at the top, so every point is flipped
/// vertically before drawing.
struct SkeletonOverlayView: View {
    let frame: PoseFrame?

    /// Bone connections drawn between joint pairs, by name.
    private static let bones: [(JointName, JointName)] = [
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.neck, .nose),
        (.neck, .root),
    ]

    private static let minJointConfidence: Float = 0.2

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }

            func point(for name: JointName) -> CGPoint? {
                guard let joint = frame.joints[name], joint.confidence >= Self.minJointConfidence else {
                    return nil
                }
                return CGPoint(x: joint.x * size.width, y: (1 - joint.y) * size.height)
            }

            for (a, b) in Self.bones {
                guard let pointA = point(for: a), let pointB = point(for: b) else { continue }
                var path = Path()
                path.move(to: pointA)
                path.addLine(to: pointB)
                context.stroke(path, with: .color(.green), lineWidth: 3)
            }

            for name in JointName.allCases {
                guard let p = point(for: name) else { continue }
                let radius: CGFloat = 5
                let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.yellow))
            }
        }
        .allowsHitTesting(false)
    }
}
