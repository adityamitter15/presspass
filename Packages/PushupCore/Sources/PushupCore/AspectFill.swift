import CoreGraphics

/// Geometry for an image shown "aspect fill": scaled uniformly until it
/// covers the view, centred, with the overflow cropped. The camera preview
/// is shown this way, so anything drawn over it in normalized image
/// coordinates has to go through the same fit to land on the right pixels.
public enum AspectFill {

    /// The rectangle, in the view's coordinates, that the whole image
    /// occupies. It is at least as large as the view on both axes and
    /// extends past it on the cropped one.
    ///
    /// - Parameters:
    ///   - imageAspect: image width divided by image height.
    ///   - viewSize: the size of the view the image fills.
    public static func rect(imageAspect: CGFloat, in viewSize: CGSize) -> CGRect {
        guard imageAspect > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let viewAspect = viewSize.width / viewSize.height
        let drawn: CGSize
        if imageAspect > viewAspect {
            // Image is relatively wider than the view: match heights, crop the sides.
            drawn = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        } else {
            // Image is relatively taller: match widths, crop top and bottom.
            drawn = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        }
        return CGRect(
            x: (viewSize.width - drawn.width) / 2,
            y: (viewSize.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// Maps a point given in normalized image coordinates with the origin at
    /// the top-left (x right, y down, both 0 to 1) into the view.
    public static func point(
        normalizedTopLeft point: CGPoint,
        imageAspect: CGFloat,
        in viewSize: CGSize
    ) -> CGPoint {
        let image = rect(imageAspect: imageAspect, in: viewSize)
        return CGPoint(x: image.minX + point.x * image.width, y: image.minY + point.y * image.height)
    }
}
