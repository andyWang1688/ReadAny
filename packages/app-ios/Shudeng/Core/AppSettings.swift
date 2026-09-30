// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 主题色：黑白灰是底子，只换一个强调色（滑杆、分段选中、发送键、进度、奖章、标签栏选中）。
enum AccentTheme: String, CaseIterable, Identifiable {
    case graphite
    case blue
    case indigo
    case purple
    case magenta
    case orange
    case yellow
    case green
    case mint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .graphite: "石墨"
        case .blue: "蓝"
        case .indigo: "靛蓝"
        case .purple: "紫"
        case .magenta: "洋红"
        case .orange: "橙"
        case .yellow: "黄"
        case .green: "绿"
        case .mint: "薄荷"
        }
    }

    var color: Color {
        switch self {
        case .graphite: Color.primary
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .indigo: Color(red: 0.37, green: 0.36, blue: 0.90)
        case .purple: Color(red: 0.75, green: 0.35, blue: 0.95)
        case .magenta: Color(red: 1.0, green: 0.22, blue: 0.37)
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .yellow: Color(red: 1.0, green: 0.80, blue: 0.0)
        case .green: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .mint: Color(red: 0.35, green: 0.85, blue: 0.84)
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper
    case eye
    case ink

    var id: String { rawValue }

    /// 老版本存的是 light / sepia / dark / oled，升级后映射到新的三套。
    static func resolve(_ raw: String?) -> ReaderTheme? {
        switch raw {
        case "paper", "light": .paper
        case "eye", "sepia": .eye
        case "ink", "dark", "oled": .ink
        default: nil
        }
    }

    var label: String {
        switch self {
        case .paper: "白"
        case .eye: "护眼"
        case .ink: "黑"
        }
    }

    var background: Color {
        switch self {
        case .paper: Color(red: 1, green: 1, blue: 1)
        case .eye: Color(red: 0.851, green: 0.914, blue: 0.816)
        case .ink: Color(white: 0)
        }
    }

    var foreground: Color {
        switch self {
        case .paper: Color(red: 0.102, green: 0.102, blue: 0.102)
        case .eye: Color(red: 0.173, green: 0.220, blue: 0.165)
        case .ink: Color(red: 0.847, green: 0.847, blue: 0.855)
        }
    }

    /// 次要文字（页脚 / 提示）。以前用 foreground.opacity(0.5) 转 hex，
    /// 但 hexString 只取 RGB、丢掉 alpha，结果和正文一模一样 —— 直接给真正的灰。
    var muted: Color {
        switch self {
        case .paper: Color(red: 0.545, green: 0.545, blue: 0.545)
        case .eye: Color(red: 0.427, green: 0.490, blue: 0.400)
        case .ink: Color(red: 0.478, green: 0.478, blue: 0.494)
        }
    }

    /// reader.html 的主题模式：只用来判断「是不是深色」（PDF 反色走这条）。
    var mode: String {
        switch self {
        case .paper: "light"
        case .eye: "eye"
        case .ink: "oled"
        }
    }

    /// 传给 reader.html 的颜色字典。
    var payload: [String: String] {
        [
            "background": background.hexString,
            "foreground": foreground.hexString,
            "muted": muted.hexString,
            "primary": foreground.hexString,
        ]
    }
}

/// 阅读器 + 外观设置，落在 UserDefaults。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var accent: AccentTheme { didSet { defaults.set(accent.rawValue, forKey: "app.accent") } }
    @Published var readerTheme: ReaderTheme { didSet { defaults.set(readerTheme.rawValue, forKey: "reader.theme") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "reader.fontSize") } }
    @Published var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: "reader.lineHeight") } }
    @Published var paragraphSpacing: Double { didSet { defaults.set(paragraphSpacing, forKey: "reader.paragraphSpacing") } }
    @Published var pageMargin: Double { didSet { defaults.set(pageMargin, forKey: "reader.pageMargin") } }
    /// false = 左右翻页（分页），true = 上下连续滚动。
    @Published var continuousScroll: Bool { didSet { defaults.set(continuousScroll, forKey: "reader.continuousScroll") } }
    @Published var serifFont: Bool { didSet { defaults.set(serifFont, forKey: "reader.serif") } }
    @Published var justify: Bool { didSet { defaults.set(justify, forKey: "reader.justify") } }
    @Published var highlightColor: String { didSet { defaults.set(highlightColor, forKey: "reader.highlightColor") } }
    @Published var ttsRate: Double { didSet { defaults.set(ttsRate, forKey: "tts.rate") } }

    init() {
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accent = AccentTheme(rawValue: defaults.string(forKey: "app.accent") ?? "") ?? .graphite
        readerTheme = ReaderTheme.resolve(defaults.string(forKey: "reader.theme")) ?? .paper
        fontSize = defaults.object(forKey: "reader.fontSize") as? Double ?? 18
        lineHeight = defaults.object(forKey: "reader.lineHeight") as? Double ?? 1.6
        paragraphSpacing = defaults.object(forKey: "reader.paragraphSpacing") as? Double ?? 16
        pageMargin = defaults.object(forKey: "reader.pageMargin") as? Double ?? 20
        continuousScroll = defaults.object(forKey: "reader.continuousScroll") as? Bool ?? false
        serifFont = defaults.object(forKey: "reader.serif") as? Bool ?? false
        justify = defaults.object(forKey: "reader.justify") as? Bool ?? true
        highlightColor = defaults.string(forKey: "reader.highlightColor") ?? "yellow"
        ttsRate = defaults.object(forKey: "tts.rate") as? Double ?? 0.5
    }

    /// reader.html 的 applySettings 载荷。
    var readerPayload: [String: Any] {
        [
            "fontSize": fontSize,
            "lineHeight": lineHeight,
            "paragraphSpacing": paragraphSpacing,
            "pageMargin": pageMargin,
            "fontTheme": serifFont ? "literata" : "system",
            // reader.html 默认 useBookFonts=true，书籍自带字体优先；不显式关掉的话
            // 上面的 fontTheme 会被书的 CSS 顶掉，「衬线字体」开关看起来没反应。
            "useBookFonts": !serifFont,
            "justifyBodyText": justify,
            "viewMode": continuousScroll ? "scroll" : "paginated",
        ]
    }
}

extension Color {
    var hexString: String {
        let ui = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}
