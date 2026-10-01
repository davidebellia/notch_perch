import AppKit

@main
enum ShelfPointerGeometryTests {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = NSRect(x: 620, y: 868, width: 200, height: 32)
        let panel = NSRect(x: 440, y: 772, width: 560, height: 128)
        let top = NSPoint(x: 720, y: 900)
        for frame in [screen, notch, panel] {
            precondition(ShelfPointerGeometry.contains(top, in: frame), "Physical top edge remains inside")
            precondition(ShelfPointerGeometry.contains(NSPoint(x: 720, y: 899), in: frame), "Interior remains inside")
            precondition(!ShelfPointerGeometry.contains(NSPoint(x: 720, y: 901), in: frame), "Above screen remains outside")
            precondition(!ShelfPointerGeometry.contains(NSPoint(x: frame.minX - 1, y: frame.midY), in: frame), "Left exterior remains outside")
            precondition(!ShelfPointerGeometry.contains(NSPoint(x: frame.maxX, y: frame.midY), in: frame), "Right boundary keeps existing semantics")
            precondition(!ShelfPointerGeometry.contains(NSPoint(x: frame.midX, y: frame.minY - 1), in: frame), "Below remains outside")
        }
        for y in stride(from: 869.0, through: 900.0, by: 1.0) {
            precondition(ShelfPointerGeometry.contains(NSPoint(x: 720, y: y), in: notch), "Upward movement stays in notch")
        }
        let secondary = NSRect(x: -1440, y: -900, width: 1440, height: 900)
        precondition(ShelfPointerGeometry.contains(NSPoint(x: -720, y: 0), in: secondary), "Negative-coordinate display top edge is included")
        precondition(!ShelfPointerGeometry.contains(top, in: .zero), "Empty frame remains outside")
        print("PASS: shelf pointer top edge and exit boundaries")
    }
}
