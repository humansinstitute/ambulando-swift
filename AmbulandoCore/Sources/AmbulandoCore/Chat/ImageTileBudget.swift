import CoreGraphics

/// How large to decode an image that fills a square tile (composer thumbnails). A cropped tile shows the image's short
/// side across it, so the decode's long edge is chosen from the image's own pixel size (read from its metadata, no
/// decode) so that the short side covers the tile. The long edge never exceeds `cap` or the image itself: an image
/// more elongated than `cap` : tile comes out softer across the tile rather than decoding more.
public enum ImageTileBudget {
    public static let cap: CGFloat = 4096

    /// `tile` is the tile's side in pixels; `width`/`height` the image's pixel size (nil or non-positive when unknown).
    public static func longEdge(tile: CGFloat, width: CGFloat?, height: CGFloat?, cap: CGFloat = cap) -> CGFloat {
        let tile = tile.isFinite ? max(1, tile) : 1
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 else { return min(cap, tile) }
        let long = max(width, height), short = min(width, height)
        return min(cap, long, tile * long / short)
    }
}
