import Cocoa

enum WhisperOwnBrand {
    static let ink = NSColor(red: 0.025, green: 0.075, blue: 0.105, alpha: 1)
    static let teal = NSColor(red: 0.38, green: 0.82, blue: 0.79, alpha: 1)
    static let amber = NSColor(red: 0.93, green: 0.62, blue: 0.28, alpha: 1)
    static let paper = NSColor(red: 0.93, green: 0.95, blue: 0.94, alpha: 1)

    static func displayFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }

    static func heroImageView() -> NSImageView {
        let imageView = NSImageView()
        if let url = Bundle.main.url(forResource: "BrandHero", withExtension: "png") {
            imageView.image = NSImage(contentsOf: url)
        } else {
            imageView.image = NSApp.applicationIconImage
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityLabel("WhisperOwn character speaking into a studio microphone")
        return imageView
    }
}
