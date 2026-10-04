import AVFoundation
import SwiftUI

/// Thin `UIViewRepresentable` wrapper around an `AVCaptureVideoPreviewLayer`
/// so `WorkoutView` can show the live camera feed inside a SwiftUI layout.
/// With no layer (a replay source has no camera image) it shows a plain dark
/// background instead.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = previewLayer
    }

    final class PreviewContainerView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                backgroundColor = previewLayer == nil ? Self.placeholderColor : nil
                guard previewLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let previewLayer, previewLayer.superlayer !== layer {
                    layer.addSublayer(previewLayer)
                }
                setNeedsLayout()
            }
        }

        private static let placeholderColor = UIColor(white: 0.07, alpha: 1)

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}
