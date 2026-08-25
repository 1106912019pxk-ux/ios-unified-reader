//
//  MarkdownView.swift
//  Aidoku
//
//  Created by Skitty on 5/20/25.
//

import MarkdownUI
import SwiftUI

func textReaderLocalized(_ key: String, fallback: String) -> String {
    let language = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
    let simplifiedChinese = [
        "TEXT_TOP_PADDING": "上间距",
        "TEXT_BOTTOM_PADDING": "下间距",
        "TEXT_PARAGRAPH_SPACING": "段落间距",
        "TEXT_FIRST_LINE_INDENT": "首行缩进（字）",
        "TEXT_BACKGROUND_COLOR": "背景颜色",
        "TEXT_BACKGROUND_SYSTEM": "跟随系统",
        "TEXT_BACKGROUND_WHITE": "纯白",
        "TEXT_BACKGROUND_WARM_PAPER": "暖纸色",
        "TEXT_BACKGROUND_SOFT_GREEN": "柔和绿",
        "TEXT_BACKGROUND_MIST_BLUE": "雾蓝色",
        "TEXT_BACKGROUND_SOFT_GRAY": "柔灰色",
        "TEXT_BACKGROUND_BLACK": "黑色",
        "IMPORTED_FONTS": "已导入字体",
        "IMPORT_TTF_OTF_FONT": "导入 TTF/OTF 字体",
        "AUTO_READING": "自动阅读",
        "AUTO_READING_SPEED": "自动阅读速度",
        "AUTO_READING_START": "开始自动阅读",
        "AUTO_READING_STOP": "停止自动阅读"
    ]
    let traditionalChinese = [
        "TEXT_TOP_PADDING": "上間距",
        "TEXT_BOTTOM_PADDING": "下間距",
        "TEXT_PARAGRAPH_SPACING": "段落間距",
        "TEXT_FIRST_LINE_INDENT": "首行縮進（字）",
        "TEXT_BACKGROUND_COLOR": "背景顏色",
        "TEXT_BACKGROUND_SYSTEM": "跟隨系統",
        "TEXT_BACKGROUND_WHITE": "純白",
        "TEXT_BACKGROUND_WARM_PAPER": "暖紙色",
        "TEXT_BACKGROUND_SOFT_GREEN": "柔和綠",
        "TEXT_BACKGROUND_MIST_BLUE": "霧藍色",
        "TEXT_BACKGROUND_SOFT_GRAY": "柔灰色",
        "TEXT_BACKGROUND_BLACK": "黑色",
        "IMPORTED_FONTS": "已匯入字體",
        "IMPORT_TTF_OTF_FONT": "匯入 TTF/OTF 字體",
        "AUTO_READING": "自動閱讀",
        "AUTO_READING_SPEED": "自動閱讀速度",
        "AUTO_READING_START": "開始自動閱讀",
        "AUTO_READING_STOP": "停止自動閱讀"
    ]
    if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") {
        return traditionalChinese[key] ?? fallback
    }
    if language.hasPrefix("zh") {
        return simplifiedChinese[key] ?? fallback
    }
    return NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}

enum TextReaderTheme: String, CaseIterable {
    case system
    case white
    case warmPaper
    case softGreen
    case mistBlue
    case softGray
    case black

    static var current: TextReaderTheme {
        UserDefaults.standard.string(forKey: "Reader.textBackgroundColor")
            .flatMap(TextReaderTheme.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: textReaderLocalized("TEXT_BACKGROUND_SYSTEM", fallback: "Follow System")
        case .white: textReaderLocalized("TEXT_BACKGROUND_WHITE", fallback: "White")
        case .warmPaper: textReaderLocalized("TEXT_BACKGROUND_WARM_PAPER", fallback: "Warm Paper")
        case .softGreen: textReaderLocalized("TEXT_BACKGROUND_SOFT_GREEN", fallback: "Soft Green")
        case .mistBlue: textReaderLocalized("TEXT_BACKGROUND_MIST_BLUE", fallback: "Mist Blue")
        case .softGray: textReaderLocalized("TEXT_BACKGROUND_SOFT_GRAY", fallback: "Soft Gray")
        case .black: textReaderLocalized("TEXT_BACKGROUND_BLACK", fallback: "Black")
        }
    }

    var backgroundColor: UIColor {
        switch self {
        case .system: .systemBackground
        case .white: .white
        case .warmPaper: UIColor(red: 0.969, green: 0.941, blue: 0.855, alpha: 1)
        case .softGreen: UIColor(red: 0.910, green: 0.949, blue: 0.898, alpha: 1)
        case .mistBlue: UIColor(red: 0.902, green: 0.933, blue: 0.957, alpha: 1)
        case .softGray: UIColor(red: 0.910, green: 0.898, blue: 0.871, alpha: 1)
        case .black: UIColor(red: 0.055, green: 0.055, blue: 0.059, alpha: 1)
        }
    }

    var foregroundColor: UIColor {
        switch self {
        case .system: .label
        case .black: UIColor(white: 0.92, alpha: 1)
        default: UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1)
        }
    }

    var secondaryForegroundColor: UIColor {
        foregroundColor.withAlphaComponent(0.65)
    }
}

struct MarkdownView: View {
    @State private var markdownString: String
    @State private var safariUrl: URL?
    @State private var showSafari = false

    let fontFamily: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let paragraphSpacing: CGFloat
    let firstLineIndent: CGFloat
    let theme: TextReaderTheme

    init(
        _ markdownString: String,
        fontFamily: String = "System",
        fontSize: CGFloat = 18,
        lineSpacing: CGFloat = 8,
        horizontalPadding: CGFloat = 16,
        topPadding: CGFloat = 32,
        bottomPadding: CGFloat = 32,
        paragraphSpacing: CGFloat = 12,
        firstLineIndent: CGFloat = 0,
        theme: TextReaderTheme = .current
    ) {
        self.markdownString = Self.indentParagraphs(in: markdownString, by: firstLineIndent)
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.horizontalPadding = horizontalPadding
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.paragraphSpacing = paragraphSpacing
        self.firstLineIndent = firstLineIndent
        self.theme = theme
    }

    private var textFont: Font {
        guard let name = TextReaderFontResolver.resolvedName(for: fontFamily) else {
            return .system(size: fontSize)
        }
        return .custom(name, size: fontSize)
    }

    private var resolvedFontFamily: String {
        TextReaderFontResolver.resolvedName(for: fontFamily) ?? ".AppleSystemUIFont"
    }

    var body: some View {
        Markdown {
            markdownString
        }
        .markdownImageProvider(LocalFileImageProvider())
        .markdownTextStyle {
            FontFamily(.custom(resolvedFontFamily))
            FontSize(fontSize)
        }
        .markdownBlockStyle(\.paragraph) { configuration in
            configuration.label
                .lineSpacing(lineSpacing)
                .padding(.bottom, paragraphSpacing)
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                if url.scheme == "http" || url.scheme == "https" {
                    safariUrl = url
                    showSafari = true
                }
                return .handled
            }
        )
        .foregroundStyle(Color(uiColor: theme.foregroundColor))
        .textSelection(.enabled)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .background(Color(uiColor: theme.backgroundColor))
        .fullScreenCover(isPresented: $showSafari) {
            SafariView(url: $safariUrl)
                .ignoresSafeArea()
        }
    }

    /// MarkdownUI has no first-line-indent modifier. Prefix only ordinary prose
    /// paragraphs so headings, lists, quotes and images retain their native layout.
    private static func indentParagraphs(in markdown: String, by indent: CGFloat) -> String {
        let count = max(0, Int(indent.rounded()))
        guard count > 0 else { return markdown }
        let prefix = String(repeating: "　", count: count)
        var startsParagraph = true

        return markdown.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { startsParagraph = trimmed.isEmpty }
            guard startsParagraph, !trimmed.isEmpty, isPlainParagraph(trimmed) else { return line }
            return prefix + line
        }.joined(separator: "\n")
    }

    private static func isPlainParagraph(_ line: String) -> Bool {
        let markdownPrefixes = ["#", ">", "- ", "* ", "+ ", "![", "```", "~~~", "<"]
        if markdownPrefixes.contains(where: { line.hasPrefix($0) }) { return false }
        if let first = line.first, first.isNumber, line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }
}

/// Loads file urls (e.g. images extracted from epubs) directly from disk,
/// since the default provider only handles network urls.
private struct LocalFileImageProvider: ImageProvider {
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}
