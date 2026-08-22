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
        case dark
    }

    static let defaultReadingModeKey = "EBook.defaultReadingMode"
    static let defaultThemeKey = "EBook.defaultTheme"
    static let defaultPublisherStylesKey = "EBook.defaultPublisherStyles"
    static let keepScreenAwakeKey = "EBook.keepScreenAwake"

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

    init(
        theme: Theme = .system,
        fontFamily: String? = nil,
        fontSize: Double = 1,
        lineHeight: Double = 1.5,
        pageMargins: Double = 1,
        topMargin: Double = 34,
        bottomMargin: Double = 34,
        paragraphIndent: Double = 0,
        paragraphSpacing: Double = 0,
        isScrollEnabled: Bool = false,
        usesPublisherStyles: Bool = true
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
    }

    static func registerGlobalDefaults() {
        UserDefaults.standard.register(defaults: [
            defaultReadingModeKey: "paged",
            defaultThemeKey: Theme.system.rawValue,
            defaultPublisherStylesKey: true,
            keepScreenAwakeKey: false,
        ])
    }

    static var globalDefaults: Self {
        registerGlobalDefaults()
        let defaults = UserDefaults.standard
        return Self(
            theme: Theme(rawValue: defaults.string(forKey: defaultThemeKey) ?? "") ?? .system,
            isScrollEnabled: defaults.string(forKey: defaultReadingModeKey) == "scroll",
            usesPublisherStyles: defaults.bool(forKey: defaultPublisherStylesKey)
        )
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 1
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.5
        pageMargins = try container.decodeIfPresent(Double.self, forKey: .pageMargins) ?? 1
        topMargin = try container.decodeIfPresent(Double.self, forKey: .topMargin) ?? 34
        bottomMargin = try container.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? 34
        paragraphIndent = try container.decodeIfPresent(Double.self, forKey: .paragraphIndent) ?? 0
        paragraphSpacing = try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0
        isScrollEnabled = try container.decodeIfPresent(Bool.self, forKey: .isScrollEnabled) ?? false
        usesPublisherStyles = try container.decodeIfPresent(Bool.self, forKey: .usesPublisherStyles) ?? true
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
