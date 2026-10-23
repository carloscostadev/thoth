import SwiftUI
import AppKit

/// Single source of truth for the app's look: palette (light + dark), type scale,
/// spacing, radii and card styles. Views should not use literal colors or sizes.
///
/// Direction: monochrome and technical (after polar.sh). A near-black grey scale in
/// dark mode, white/grey-50 in light mode, hairline borders, a large light display
/// number, monospaced labels and values, and color only where it carries meaning
/// (categories, models, status) — always desaturated.
enum Theme {

    // MARK: - Palette

    enum Palette {
        // Neutrals — dark mode follows the polar scale (950 / 800 / 700 / 600).
        static let background    = Color(light: 0xFFFFFF, dark: 0x090909)
        static let surface       = Color(light: 0xF9FAFB, dark: 0x181818)
        static let surfaceRaised = Color(light: 0xF3F4F6, dark: 0x292929)
        static let border        = Color(light: 0xE5E7EB, dark: 0x212121)
        static let track         = Color(light: 0xE5E7EB, dark: 0x262626)

        // Text — dark: white / polar-300 / polar-500.
        static let textPrimary   = Color(light: 0x0A0A0A, dark: 0xFFFFFF)
        static let textSecondary = Color(light: 0x6B7280, dark: 0x9E9E9E)
        static let textTertiary  = Color(light: 0x7C828D, dark: 0x757575)

        /// The one subtle accent: live / selected state.
        static let accent   = Color(light: 0x2F6FEB, dark: 0x6B9BFF)
        static let positive = Color(light: 0x2F8A57, dark: 0x7CC49A)
        static let negative = Color(light: 0xB0533F, dark: 0xD99484)

        /// Semantic aliases: money and tokens stay monochrome.
        static let cost   = textPrimary
        static let tokens = textSecondary

        // Desaturated data hues (categories / models).
        fileprivate static let slateBlue = Color(light: 0x4F6788, dark: 0x8DA2C0)
        fileprivate static let sage      = Color(light: 0x4D7A60, dark: 0x8FB8A0)
        fileprivate static let lavender  = Color(light: 0x6B5C8E, dark: 0xA99BC6)
        fileprivate static let sand      = Color(light: 0x8E6A4D, dark: 0xC9A68A)
        fileprivate static let khaki     = Color(light: 0x7D7445, dark: 0xC4BA8A)
        fileprivate static let dustyRose = Color(light: 0x8C5673, dark: 0xC495AE)
        fileprivate static let clay      = Color(light: 0x94604A, dark: 0xD0A089)
        fileprivate static let seafoam   = Color(light: 0x4B7A74, dark: 0x8CB5B0)
    }

    // MARK: - Category / model / state accents

    static func color(for category: ActivityCategory) -> Color {
        switch category {
        case .conversation: return Palette.slateBlue
        case .coding: return Palette.sage
        case .exploration: return Palette.lavender
        case .terminal: return Palette.sand
        case .planning: return Palette.khaki
        case .design: return Palette.dustyRose
        }
    }

    static func color(for family: ModelFamily?) -> Color {
        switch family {
        case .opus: return Palette.clay
        case .sonnet: return Palette.slateBlue
        case .haiku: return Palette.seafoam
        case .fable, .mythos: return Palette.lavender
        case nil: return Palette.textTertiary
        }
    }

    static func color(for state: ActivityState) -> Color {
        switch state {
        case .sleep: return Palette.textTertiary
        case .idle: return Palette.textSecondary
        case .active: return Palette.positive
        case .sprint: return Palette.negative
        }
    }

    static func connectionColor(_ isConnected: Bool) -> Color {
        isConnected ? Palette.positive : Palette.textTertiary
    }

    /// Daily chart bar fill: grey bars, the selected one in full contrast.
    static func chartBar(hasValue: Bool, isSelected: Bool, isDimmed: Bool) -> Color {
        guard hasValue else { return Palette.track }
        if isSelected { return Palette.textPrimary }
        return Palette.textTertiary.opacity(isDimmed ? 0.45 : 1)
    }

    /// Heatmap cell fill for a 0...1 intensity: a greyscale ramp towards the text color.
    static func heat(_ intensity: Double) -> Color {
        if intensity <= 0 { return Palette.track }
        return Palette.textPrimary.opacity(0.14 + min(intensity, 1) * 0.86)
    }

    // MARK: - Typography

    enum Font {
        /// The big number of the popover (today's cost): light display.
        static let hero = SwiftUI.Font.system(size: 40, weight: .regular).monospacedDigit()
        /// Prominent numbers inside cards.
        static let metric = SwiftUI.Font.system(size: 22, weight: .regular).monospacedDigit()
        static let title = SwiftUI.Font.system(size: 13, weight: .medium)
        static let body = SwiftUI.Font.system(size: 12, weight: .regular)
        static let bodyEmphasis = SwiftUI.Font.system(size: 12, weight: .medium)
        /// Numeric values in rows.
        static let number = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let captionNumber = SwiftUI.Font.system(size: 10, weight: .regular, design: .monospaced)
        static let micro = SwiftUI.Font.system(size: 10, weight: .regular)
        static let microNumber = SwiftUI.Font.system(size: 9, weight: .regular, design: .monospaced)
        /// Small uppercase technical labels (used with `tracking`).
        static let sectionLabel = SwiftUI.Font.system(size: 10, weight: .medium, design: .monospaced)
        static let tab = SwiftUI.Font.system(size: 12, weight: .medium)
        static let icon = SwiftUI.Font.system(size: 11, weight: .regular)
    }

    /// Letter spacing for uppercase monospaced labels.
    static let labelTracking: CGFloat = 1.0

    // MARK: - Spacing, radii, sizes

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let bar: CGFloat = 2
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    enum Size {
        static let popoverWidth: CGFloat = 400
        /// Fixed height of the scrolling tab content. A ScrollView has no ideal height,
        /// so inside a MenuBarExtra window it collapses unless given one explicitly.
        /// Capped so header + tabs + footer still fit on small screens.
        static var contentHeight: CGFloat {
            let visible = NSScreen.main?.visibleFrame.height ?? 900
            return max(280, min(520, visible - 360))
        }
        static let dot: CGFloat = 6
        static let barHeight: CGFloat = 4
        static let thinBarHeight: CGFloat = 3
        static let chartHeight: CGFloat = 88
        static let heatmapCellGap: CGFloat = 2
        static let hairline: CGFloat = 1
    }
}

// MARK: - Card styles

enum CardStyle {
    /// Standard content card: surface fill + hairline border.
    case plain
    /// Hero card: same shape, a faint top highlight and more breathing room.
    case hero
}

private struct ThemeCardModifier: ViewModifier {
    let style: CardStyle
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style == .hero ? Theme.Radius.lg : Theme.Radius.md,
                                     style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                switch style {
                case .plain:
                    shape.fill(Theme.Palette.surface)
                case .hero:
                    shape.fill(Theme.Palette.surface)
                        .overlay(
                            shape.fill(LinearGradient(
                                colors: [Theme.Palette.textPrimary.opacity(0.04), .clear],
                                startPoint: .top,
                                endPoint: .center
                            ))
                        )
                }
            }
            .overlay(shape.strokeBorder(Theme.Palette.border, lineWidth: Theme.Size.hairline))
    }
}

/// Uppercase monospaced section heading with optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            ThemeLabel(title)
            Spacer(minLength: Theme.Spacing.sm)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

/// Small uppercase monospaced label ("TODAY", "TOKENS").
struct ThemeLabel: View {
    let text: String
    var color: Color = Theme.Palette.textTertiary

    init(_ text: String, color: Color = Theme.Palette.textTertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.sectionLabel)
            .tracking(Theme.labelTracking)
            .foregroundStyle(color)
    }
}

/// Capsule chip with hairline border, optional leading status dot.
struct ThemeChip: View {
    let text: String
    var dot: Color? = nil
    var textColor: Color = Theme.Palette.textSecondary

    var body: some View {
        HStack(spacing: Theme.Spacing.xs + 1) {
            if let dot {
                Circle().fill(dot).frame(width: Theme.Size.dot, height: Theme.Size.dot)
            }
            Text(text.uppercased())
                .font(Theme.Font.captionNumber)
                .tracking(Theme.labelTracking / 2)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, Theme.Spacing.sm + 2)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Capsule().fill(Theme.Palette.background))
        .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: Theme.Size.hairline))
    }
}

/// Horizontal progress bar on a neutral track.
struct ThemeBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = Theme.Size.barHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}

/// Hairline separator in the theme's border color.
struct ThemeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(height: Theme.Size.hairline)
    }
}

extension View {
    func themeCard(_ style: CardStyle = .plain, padding: CGFloat = Theme.Spacing.lg) -> some View {
        modifier(ThemeCardModifier(style: style, padding: padding))
    }
}


// MARK: - Adaptive colors

extension Color {
    /// A color that resolves per appearance (light / dark), from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
