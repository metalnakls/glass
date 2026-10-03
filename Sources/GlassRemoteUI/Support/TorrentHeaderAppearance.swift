import AppKit

struct TorrentHeaderAppearance: Equatable {
    var strength = 0.75
    var reach: CGFloat = 48
    var backgroundIn = 0.22
    var backgroundOut = 0.28
    var titleIn = 0.18
    var titleOut = 0.22
    var pushLead: CGFloat = 0
    var color = NSColor.white
}

enum HeaderFadeColor {
    static func decode(_ hex: String) -> NSColor {
        guard let value = UInt32(hex, radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func encode(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
