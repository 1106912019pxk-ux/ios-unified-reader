//
//  EBookModels.swift
//  Aidoku
//
//  Local e-book models. These are intentionally separate from manga models.
//

import Foundation

enum EBookFormat: String, Codable, CaseIterable, Sendable {
    case epub
    case pdf
    case text
    case markdown
    case html

    static func detect(from url: URL) -> EBookFormat? {
        switch url.pathExtension.lowercased() {
        case "epub": .epub
        case "pdf": .pdf
        case "txt": .text
        case "md", "markdown": .markdown
        case "html", "htm": .html
        default: nil
        }
    }

    var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .text: "TXT"
        case .markdown: "Markdown"
        case .html: "HTML"
        }
    }
}

struct EBookBookmark: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var locatorJSON: String
    var createdAt: Date = Date()
}

struct EBookPreferences: Codable, Hashable, Sendable {
    enum Theme: String, Codable, CaseIterable, Sendable {
        case system
        case light
        case sepia
        case green
        case blue
        case dark
    }

    static let defaultReadingModeKey = "EBook.defaultReadingMode"
    static let defaultThemeKey = "EBook.defaultTheme"
    static let defaultPublisherStylesKey = "EBook.defaultPublisherStyles"
    static let keepScreenAwakeKey = "EBook.keepScreenAwake"
    static let defaultFontFamilyKey = "EBook.defaultFontFamily"
    static let defaultFontSizeKey = "EBook.defaultFontSize"
    static let defaultLineHeightKey = "EBook.defaultLineHeight"
    static let defaultPageMarginsKey = "EBook.defaultPageMargins"
    static let defaultTopMarginKey = "EBook.defaultTopMargin"
    static let defaultBottomMarginKey = "EBook.defaultBottomMargin"
    static let defaultParagraphIndentKey = "EBook.defaultParagraphIndent"
    static let defaultParagraphSpacingKey = "EBook.defaultParagraphSpacing"
    private static let typographyUnitsVersionKey = "EBook.typographyUnitsVersion"
    private static let currentTypographyUnitsVersion = 2

    var theme: Theme
    var fontFamily: String?
    var fontSize: Double
    var lineHeight: Double
    var pageMargins: Double
    var topMargin: Double
    var bottomMargin: Double
    var paragraphIndent: Double
    var paragraphSpacing: Double
    var isScrollEnabled: Bool
    var usesPublisherStyles: Bool
    private var typographyUnitsVersion: Int

    init(
        theme: Theme = .system,
        fontFamily: String? = nil,
        fontSize: Double = 24,
        lineHeight: Double = 15,
        pageMargins: Double = 25,
        topMargin: Double = 30,
        bottomMargin: Double = 20,
        paragraphIndent: Double = 2,
        paragraphSpacing: Double = 5,
        isScrollEnabled: Bool = false,
        usesPublisherStyles: Bool = false
    ) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.pageMargins = pageMargins
        self.topMargin = topMargin
        self.bottomMargin = bottomMargin
        self.paragraphIndent = paragraphIndent
        self.paragraphSpacing = paragraphSpacing
        self.isScrollEnabled = isScrollEnabled
        self.usesPublisherStyles = usesPublisherStyles
        typographyUnitsVersion = Self.currentTypographyUnitsVersion
    }

    static func registerGlobalDefaults() {
        migrateGlobalTypographyUnitsIfNeeded()
        UserDefaults.standard.register(defaults: [
            defaultReadingModeKey: "paged",
            defaultThemeKey: Theme.system.rawValue,
            defaultPublisherStylesKey: false,
            keepScreenAwakeKey: false,
            defaultFontFamilyKey: "",
            defaultFontSizeKey: 24.0,
            defaultLineHeightKey: 15.0,
            defaultPageMarginsKey: 25.0,
            defaultTopMarginKey: 30.0,
            defaultBottomMarginKey: 20.0,
            defaultParagraphIndentKey: 2.0,
            defaultParagraphSpacingKey: 5.0,
            typographyUnitsVersionKey: currentTypographyUnitsVersion,
        ])
    }

    private static func migrateGlobalTypographyUnitsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: typographyUnitsVersionKey) < currentTypographyUnitsVersion else { return }

        func migrate(_ key: String, whenAtMost maximum: Double, transform: (Double) -> Double) {
            guard let number = defaults.object(forKey: key) as? NSNumber else { return }
            let value = number.doubleValue
            guard value <= maximum else { return }
            defaults.set(transform(value), forKey: key)
        }

        migrate(defaultFontSizeKey, whenAtMost: 3) { $0 * 24 }
        migrate(defaultLineHeightKey, whenAtMost: 3) { $0 * 10 }
        migrate(defaultPageMarginsKey, whenAtMost: 4) { $0 * 25 }
        migrate(defaultParagraphSpacingKey, whenAtMost: 2) { $0 * 10 }
        defaults.set(false, forKey: defaultPublisherStylesKey)
        defaults.set(currentTypographyUnitsVersion, forKey: typographyUnitsVersionKey)
    }

    static var globalDefaults: Self {
        registerGlobalDefaults()
        let defaults = UserDefaults.standard
        let family = defaults.string(forKey: defaultFontFamilyKey)
        return Self(
            theme: Theme(rawValue: defaults.string(forKey: defaultThemeKey) ?? "") ?? .system,
            fontFamily: family?.isEmpty == false ? family : nil,
            fontSize: defaults.double(forKey: defaultFontSizeKey),
            lineHeight: defaults.double(forKey: defaultLineHeightKey),
            pageMargins: defaults.double(forKey: defaultPageMarginsKey),
            topMargin: defaults.double(forKey: defaultTopMarginKey),
            bottomMargin: defaults.double(forKey: defaultBottomMarginKey),
            paragraphIndent: defaults.double(forKey: defaultParagraphIndentKey),
            paragraphSpacing: defaults.double(forKey: defaultParagraphSpacingKey),
            isScrollEnabled: defaults.string(forKey: defaultReadingModeKey) == "scroll",
            usesPublisherStyles: defaults.bool(forKey: defaultPublisherStylesKey)
        )
    }

    static func saveGlobalDefaults(_ preferences: Self) {
        registerGlobalDefaults()
        let defaults = UserDefaults.standard
        defaults.set(preferences.theme.rawValue, forKey: defaultThemeKey)
        defaults.set(preferences.fontFamily ?? "", forKey: defaultFontFamilyKey)
        defaults.set(preferences.fontSize, forKey: defaultFontSizeKey)
        defaults.set(preferences.lineHeight, forKey: defaultLineHeightKey)
        defaults.set(preferences.pageMargins, forKey: defaultPageMarginsKey)
        defaults.set(preferences.topMargin, forKey: defaultTopMarginKey)
        defaults.set(preferences.bottomMargin, forKey: defaultBottomMarginKey)
        defaults.set(preferences.paragraphIndent, forKey: defaultParagraphIndentKey)
        defaults.set(preferences.paragraphSpacing, forKey: defaultParagraphSpacingKey)
        defaults.set(preferences.isScrollEnabled ? "scroll" : "paged", forKey: defaultReadingModeKey)
        defaults.set(preferences.usesPublisherStyles, forKey: defaultPublisherStylesKey)
    }

    static func saveGlobalDefaultFontFamily(_ familyName: String?) {
        registerGlobalDefaults()
        let defaults = UserDefaults.standard
        defaults.set(familyName ?? "", forKey: defaultFontFamilyKey)
        if familyName != nil {
            defaults.set(false, forKey: defaultPublisherStylesKey)
        }
    }

    static var keepsScreenAwake: Bool {
        registerGlobalDefaults()
        return UserDefaults.standard.bool(forKey: keepScreenAwakeKey)
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case fontFamily
        case fontSize
        case lineHeight
        case pageMargins
        case topMargin
        case bottomMargin
        case paragraphIndent
        case paragraphSpacing
        case isScrollEnabled
        case usesPublisherStyles
        case typographyUnitsVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        typographyUnitsVersion = try container.decodeIfPresent(Int.self, forKey: .typographyUnitsVersion) ?? 1
        let usesLegacyUnits = typographyUnitsVersion < Self.currentTypographyUnitsVersion
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? (usesLegacyUnits ? 1 : 24)
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? (usesLegacyUnits ? 1.5 : 15)
        pageMargins = try container.decodeIfPresent(Double.self, forKey: .pageMargins) ?? (usesLegacyUnits ? 1 : 25)
        topMargin = try container.decodeIfPresent(Double.self, forKey: .topMargin) ?? (usesLegacyUnits ? 34 : 30)
        bottomMargin = try container.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? (usesLegacyUnits ? 34 : 20)
        paragraphIndent = try container.decodeIfPresent(Double.self, forKey: .paragraphIndent) ?? (usesLegacyUnits ? 0 : 2)
        paragraphSpacing = try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? (usesLegacyUnits ? 0 : 5)
        isScrollEnabled = try container.decodeIfPresent(Bool.self, forKey: .isScrollEnabled) ?? false
        usesPublisherStyles = try container.decodeIfPresent(Bool.self, forKey: .usesPublisherStyles) ?? true

        if usesLegacyUnits {
            fontSize *= 24
            lineHeight *= 10
            pageMargins *= 25
            paragraphSpacing *= 10
            typographyUnitsVersion = Self.currentTypographyUnitsVersion
        }
    }
}

struct EBook: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var fileName: String
    var format: EBookFormat
    var title: String
    var author: String?
    var coverFileName: String?
    var addedAt: Date
    var lastOpenedAt: Date?
    var locatorJSON: String?
    var pdfPageIndex: Int?
    var bookmarks: [EBookBookmark]
    var preferences: EBookPreferences
    var usesGlobalPreferences: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        format: EBookFormat,
        title: String,
        author: String? = nil,
        coverFileName: String? = nil,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        locatorJSON: String? = nil,
        pdfPageIndex: Int? = nil,
        bookmarks: [EBookBookmark] = [],
        preferences: EBookPreferences = EBookPreferences(),
        usesGlobalPreferences: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.format = format
        self.title = title
        self.author = author
        self.coverFileName = coverFileName
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.locatorJSON = locatorJSON
        self.pdfPageIndex = pdfPageIndex
        self.bookmarks = bookmarks
        self.preferences = preferences
        self.usesGlobalPreferences = usesGlobalPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case format
        case title
        case author
        case coverFileName
        case addedAt
        case lastOpenedAt
        case locatorJSON
        case pdfPageIndex
        case bookmarks
        case preferences
        case usesGlobalPreferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        format = try container.decode(EBookFormat.self, forKey: .format)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        coverFileName = try container.decodeIfPresent(String.self, forKey: .coverFileName)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        locatorJSON = try container.decodeIfPresent(String.self, forKey: .locatorJSON)
        pdfPageIndex = try container.decodeIfPresent(Int.self, forKey: .pdfPageIndex)
        bookmarks = try container.decodeIfPresent([EBookBookmark].self, forKey: .bookmarks) ?? []
        preferences = try container.decodeIfPresent(EBookPreferences.self, forKey: .preferences) ?? EBookPreferences()
        usesGlobalPreferences = try container.decodeIfPresent(Bool.self, forKey: .usesGlobalPreferences) ?? false
    }
}
