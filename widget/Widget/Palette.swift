import SwiftUI

/// The design's colors: a warm clay accent and softened status tones, each
/// drawn darker on a light background so it keeps its contrast. Resolved from
/// the scheme in the environment, which the per-widget Appearance forces.
/// Accented and vibrant rendering ignore all of it: the views fall back to
/// `.primary` there.
enum Palette {
    static func accent(_ scheme: ColorScheme) -> Color { pick(scheme, dark: 0xF0A877, light: 0xC2622F) }
    /// Normal percentages and the active dot.
    static func good(_ scheme: ColorScheme) -> Color { pick(scheme, dark: 0x82D18F, light: 0x2F7A3D) }
    static func warning(_ scheme: ColorScheme) -> Color { pick(scheme, dark: 0xF0C274, light: 0xA06515) }
    static func critical(_ scheme: ColorScheme) -> Color { pick(scheme, dark: 0xFF8F86, light: 0xC5392C) }
    /// The auto-switch track when on.
    static func switchOn(_ scheme: ColorScheme) -> Color { pick(scheme, dark: 0x3FAE55, light: 0x2F7A3D) }

    static func pick(_ scheme: ColorScheme, dark: UInt32, light: UInt32) -> Color {
        let hex = scheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}
