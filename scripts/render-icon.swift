import AppKit
// Render the same SF Symbol the menubar uses, macOS-app-icon style:
// dark rounded-square, subtle gradient, white mic glyph.
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let rect = NSRect(origin: .zero, size: size)
// canvas transparent; draw rounded square inset like Big Sur icons (~10% margin)
let inset = rect.insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
let grad = NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.25, alpha: 1),
                      ending: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1))!
grad.draw(in: path, angle: -90)
// the glyph
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
if let sym = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: sym.size)
    sym.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let s = tinted.size
    let scale = min(440 / s.width, 440 / s.height) * (s.width / max(s.width, s.height)) + 0.0
    let w = s.width * (520 / max(s.width, s.height))
    let h = s.height * (520 / max(s.width, s.height))
    tinted.draw(in: NSRect(x: (1024-w)/2, y: (1024-h)/2, width: w, height: h))
}
img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon-system-1024.png"))
print("rendered")
