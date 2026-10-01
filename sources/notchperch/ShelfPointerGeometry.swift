import AppKit

// NSRect.contains excludes maxY. The physical top edge must keep the shelf open.
enum ShelfPointerGeometry {
    static func contains(_ point: NSPoint, in frame: NSRect) -> Bool {
        guard !frame.isEmpty else { return false }
        return point.x >= frame.minX && point.x < frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }
}
