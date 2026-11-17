// WCAG contrast between two sRGB colours, for colours that arrive at run time
// (a user-picked project colour) — the palette itself is checked at build time
// by kit/tools/build_tokens.py.

import Foundation

enum Contrast {
    /// Relative luminance of 0xRRGGBB, 0 (black) to 1 (white).
    static func luminance(_ rgb: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel & 0xff) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
    }

    /// 1 (identical) to 21 (black on white).
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Black or white, whichever reads better on `background`.
    static func ink(on background: UInt32) -> UInt32 {
        ratio(0x000000, background) >= ratio(0xFFFFFF, background) ? 0x000000 : 0xFFFFFF
    }
}
