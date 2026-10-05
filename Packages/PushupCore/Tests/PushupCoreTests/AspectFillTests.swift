import CoreGraphics
import Testing
import PushupCore

@Suite("AspectFill")
struct AspectFillTests {
    private let portraitCamera: CGFloat = 9.0 / 16.0

    @Test("a view with the image's own aspect is covered exactly")
    func sameAspectIsIdentity() {
        let view = CGSize(width: 360, height: 640)
        let rect = AspectFill.rect(imageAspect: portraitCamera, in: view)
        #expect(abs(rect.minX) < 1e-9)
        #expect(abs(rect.minY) < 1e-9)
        #expect(abs(rect.width - 360) < 1e-9)
        #expect(abs(rect.height - 640) < 1e-9)
    }

    @Test("a taller view crops the sides and keeps the full height")
    func tallViewCropsSides() {
        // An iPhone screen is taller than 9:16, so the preview loses its edges.
        let view = CGSize(width: 402, height: 874)
        let rect = AspectFill.rect(imageAspect: portraitCamera, in: view)
        #expect(abs(rect.height - 874) < 1e-9)
        #expect(abs(rect.width - 874 * 9 / 16) < 1e-9)
        #expect(rect.width > view.width)
        // Centred: the same amount is cropped on each side.
        #expect(abs(rect.minX + (rect.width - view.width) / 2) < 1e-9)
        #expect(abs(rect.minY) < 1e-9)
    }

    @Test("a short wide view crops top and bottom and keeps the full width")
    func wideViewCropsTopAndBottom() {
        // The recorder's preview card.
        let view = CGSize(width: 360, height: 260)
        let rect = AspectFill.rect(imageAspect: portraitCamera, in: view)
        #expect(abs(rect.width - 360) < 1e-9)
        #expect(abs(rect.height - 640) < 1e-9)
        #expect(abs(rect.minY + (640 - 260) / 2) < 1e-9)
        #expect(abs(rect.minX) < 1e-9)
    }

    @Test("the image centre always maps to the view centre")
    func centreMapsToCentre() {
        for view in [CGSize(width: 402, height: 874), CGSize(width: 360, height: 260), CGSize(width: 500, height: 500)] {
            let p = AspectFill.point(
                normalizedTopLeft: CGPoint(x: 0.5, y: 0.5),
                imageAspect: portraitCamera,
                in: view
            )
            #expect(abs(p.x - view.width / 2) < 1e-9)
            #expect(abs(p.y - view.height / 2) < 1e-9)
        }
    }

    @Test("points near a cropped edge land outside the view")
    func croppedEdgeIsOffScreen() {
        let view = CGSize(width: 402, height: 874)
        let left = AspectFill.point(normalizedTopLeft: CGPoint(x: 0, y: 0.5), imageAspect: portraitCamera, in: view)
        let right = AspectFill.point(normalizedTopLeft: CGPoint(x: 1, y: 0.5), imageAspect: portraitCamera, in: view)
        #expect(left.x < 0)
        #expect(right.x > view.width)
    }

    @Test("degenerate input falls back to the view's own rectangle")
    func degenerateInput() {
        let view = CGSize(width: 100, height: 200)
        #expect(AspectFill.rect(imageAspect: 0, in: view) == CGRect(origin: .zero, size: view))
        #expect(AspectFill.rect(imageAspect: 0.5, in: .zero) == CGRect(origin: .zero, size: .zero))
    }
}
