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

    var theme: Theme = .system
    var fontFamily: String?
    var fontSize: Double = 1
    var lineHeight: Double = 1.5
    var pageMargins: Double = 1
    var paragraphSpacing: Double = 0
    var isScrollEnabled = false
    var usesPublisherStyles = true
}

struct EBook: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var fileName: String
    var format: EBookFormat
    var title: String
    var author: String?
    var addedAt: Date = Date()
    var lastOpenedAt: Date?
    var locatorJSON: String?
    var pdfPageIndex: Int?
    var bookmarks: [EBookBookmark] = []
    var preferences = EBookPreferences()
}

