//
//  TxtParser.swift
//  Aidoku
//
//  Local TXT decoding, chapter detection, indexing, and random-access reading.
//

import CoreFoundation
import CryptoKit
import Foundation

enum TxtEncoding: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case gb18030
    case big5

    var id: String { rawValue }

    var localizedName: String {
        switch self {
            case .utf8: "UTF-8"
            case .utf16LittleEndian: "UTF-16 LE"
            case .utf16BigEndian: "UTF-16 BE"
            case .gb18030: "GB18030 / GBK"
            case .big5: "Big5"
        }
    }

    fileprivate var stringEncoding: String.Encoding {
        switch self {
            case .utf8:
                .utf8
            case .utf16LittleEndian:
                .utf16LittleEndian
            case .utf16BigEndian:
                .utf16BigEndian
            case .gb18030:
                String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    )
                )
            case .big5:
                String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.big5.rawValue)
                    )
                )
        }
    }
}

struct TxtImportOptions: Hashable, Sendable {
    var encoding: TxtEncoding
    var splitsChapters: Bool
    var customChapterPattern: String?
}

struct TxtChapterIndex: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let sourceFileName: String
    let sourceHash: String
    let originalEncoding: TxtEncoding
    let chapters: [Chapter]

    struct Chapter: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let title: String
        let startOffset: UInt64
        let endOffset: UInt64
    }

    static func url(for textURL: URL) -> URL {
        textURL.appendingPathExtension("index.json")
    }

    static func load(for textURL: URL) -> TxtChapterIndex? {
        let url = url(for: textURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TxtChapterIndex.self, from: data)
    }

    func save(for textURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(for: textURL), options: .atomic)
    }
}

struct TxtAnalysis: Hashable, Sendable {
    let encoding: TxtEncoding
    let preview: String
    let index: TxtChapterIndex
}

struct TxtPreparedDocument: Sendable {
    let normalizedData: Data
    let analysis: TxtAnalysis
}

enum TxtParserError: Error, Equatable, Sendable {
    case emptyFile
    case decodingFailed
    case invalidChapterPattern
    case chapterLimitExceeded
    case invalidIndex
}

enum TxtParser {
    static let maximumChapterCount = 10_000
    static let previewCharacterCount = 1_500

    static func analyze(
        url: URL,
        options: TxtImportOptions? = nil
    ) throws -> TxtAnalysis {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try prepare(data: data, sourceFileName: url.lastPathComponent, options: options).analysis
    }

    static func prepare(
        url: URL,
        options: TxtImportOptions
    ) throws -> TxtPreparedDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try prepare(data: data, sourceFileName: url.lastPathComponent, options: options)
    }

    static func prepare(
        data: Data,
        sourceFileName: String,
        options: TxtImportOptions? = nil
    ) throws -> TxtPreparedDocument {
        guard !data.isEmpty else { throw TxtParserError.emptyFile }

        let encoding = options?.encoding ?? detectEncoding(data: data)
        guard var text = String(data: data, encoding: encoding.stringEncoding) else {
            throw TxtParserError.decodingFailed
        }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }
        text = normalizeLineEndings(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TxtParserError.emptyFile
        }

        let normalizedData = Data(text.utf8)
        let splitsChapters = options?.splitsChapters ?? true
        let customPattern = options?.customChapterPattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chapters = try buildChapterIndex(
            text: text,
            splitsChapters: splitsChapters,
            customPattern: customPattern?.isEmpty == false ? customPattern : nil
        )
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let index = TxtChapterIndex(
            version: TxtChapterIndex.currentVersion,
            sourceFileName: sourceFileName,
            sourceHash: hash,
            originalEncoding: encoding,
            chapters: chapters
        )
        let preview = String(text.prefix(previewCharacterCount))
        return TxtPreparedDocument(
            normalizedData: normalizedData,
            analysis: TxtAnalysis(encoding: encoding, preview: preview, index: index)
        )
    }

    static func readChapter(
        from textURL: URL,
        chapterId: String
    ) throws -> String {
        guard
            let index = TxtChapterIndex.load(for: textURL),
            let chapter = index.chapters.first(where: { chapterId == $0.id || chapterId.hasSuffix("/\($0.id)") }),
            chapter.endOffset >= chapter.startOffset
        else {
            throw TxtParserError.invalidIndex
        }

        let length = chapter.endOffset - chapter.startOffset
        guard length <= UInt64(Int.max) else { throw TxtParserError.invalidIndex }

        let handle = try FileHandle(forReadingFrom: textURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: chapter.startOffset)
        guard
            let data = try handle.read(upToCount: Int(length)),
            data.count == Int(length),
            let text = String(data: data, encoding: .utf8)
        else {
            throw TxtParserError.invalidIndex
        }
        return text
    }

    static func detectEncoding(data: Data) -> TxtEncoding {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }
        if String(data: data, encoding: .utf8) != nil {
            return .utf8
        }

        let sample = data.prefix(4_096)
        let evenNulls = sample.enumerated().reduce(into: 0) { count, item in
            if item.offset.isMultiple(of: 2), item.element == 0 { count += 1 }
        }
        let oddNulls = sample.enumerated().reduce(into: 0) { count, item in
            if !item.offset.isMultiple(of: 2), item.element == 0 { count += 1 }
        }
        if oddNulls > max(4, evenNulls * 3) {
            return .utf16LittleEndian
        }
        if evenNulls > max(4, oddNulls * 3) {
            return .utf16BigEndian
        }

        // GB18030 is the most common non-Unicode encoding for Simplified Chinese.
        // The import preview always allows overriding ambiguous GB18030/Big5 cases.
        if String(data: data, encoding: TxtEncoding.gb18030.stringEncoding) != nil {
            return .gb18030
        }
        if String(data: data, encoding: TxtEncoding.big5.stringEncoding) != nil {
            return .big5
        }
        return .utf8
    }

    static func validateChapterPattern(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }
}

private extension TxtParser {
    struct Heading {
        let title: String
        let offset: UInt64
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func buildChapterIndex(
        text: String,
        splitsChapters: Bool,
        customPattern: String?
    ) throws -> [TxtChapterIndex.Chapter] {
        let totalBytes = UInt64(text.utf8.count)
        guard splitsChapters else {
            return [singleChapter(endOffset: totalBytes)]
        }

        let customRegex: NSRegularExpression?
        if let customPattern {
            guard let regex = try? NSRegularExpression(pattern: customPattern, options: [.caseInsensitive]) else {
                throw TxtParserError.invalidChapterPattern
            }
            customRegex = regex
        } else {
            customRegex = nil
        }
        let defaultRegexes = customRegex == nil ? defaultChapterRegexes() : []

        var headings: [Heading] = []
        var lineStart = text.startIndex
        var byteOffset: UInt64 = 0
        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            let nextLineStart = newline.map { text.index(after: $0) } ?? text.endIndex
            let rawLine = String(text[lineStart..<lineEnd])
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, line.count <= 160 {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let matched = if let customRegex {
                    customRegex.firstMatch(in: line, range: range) != nil
                } else {
                    defaultRegexes.contains { $0.firstMatch(in: line, range: range) != nil }
                }
                if matched {
                    headings.append(Heading(title: line, offset: byteOffset))
                    if headings.count > maximumChapterCount {
                        throw TxtParserError.chapterLimitExceeded
                    }
                }
            }
            byteOffset += UInt64(text[lineStart..<nextLineStart].utf8.count)
            lineStart = nextLineStart
        }

        guard !headings.isEmpty else {
            return [singleChapter(endOffset: totalBytes)]
        }

        var chapters: [TxtChapterIndex.Chapter] = []
        let firstHeadingOffset = headings[0].offset
        let prefixHasContent: Bool
        if firstHeadingOffset > 0 {
            let prefix = Data(text.utf8).prefix(Int(firstHeadingOffset))
            prefixHasContent = String(decoding: prefix, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        } else {
            prefixHasContent = false
        }
        if prefixHasContent {
            chapters.append(.init(
                id: chapterId(chapters.count),
                title: NSLocalizedString("TXT_PREFACE", comment: "TXT preface chapter title"),
                startOffset: 0,
                endOffset: firstHeadingOffset
            ))
        }
        for (index, heading) in headings.enumerated() {
            let endOffset = headings[safe: index + 1]?.offset ?? totalBytes
            chapters.append(.init(
                id: chapterId(chapters.count),
                title: heading.title,
                startOffset: index == 0 && !prefixHasContent ? 0 : heading.offset,
                endOffset: endOffset
            ))
        }
        return chapters
    }

    static func singleChapter(endOffset: UInt64) -> TxtChapterIndex.Chapter {
        .init(
            id: chapterId(0),
            title: NSLocalizedString("TXT_BODY", comment: "TXT single chapter title"),
            startOffset: 0,
            endOffset: endOffset
        )
    }

    static func chapterId(_ index: Int) -> String {
        String(format: "txt-%05d", index + 1)
    }

    static func defaultChapterRegexes() -> [NSRegularExpression] {
        let patterns = [
            #"^(?:正文\s*)?第[零〇一二两三四五六七八九十百千万亿0-9０-９]+[卷部篇章回节集话](?:\s*[-—_:：.]?\s*[^\n]{0,60})?$"#,
            #"^(?:序章|序言|前言|楔子|引子|后记|尾声|终章|大结局|番外(?:篇)?|附录)(?:\s*[-—_:：.]?\s*[^\n]{0,50})?$"#,
            #"^(?:chapter|part|volume|book)\s+[0-9ivxlcdm]+(?:\s*[-—_:：.]?\s*[^\n]{0,60})?$"#,
            #"^第[0-9０-９一二三四五六七八九十百千万]+[話章巻](?:\s*[-—_:：.]?\s*[^\n]{0,60})?$"#,
            #"^(?:プロローグ|エピローグ|序章|終章)(?:\s*[-—_:：.]?\s*[^\n]{0,50})?$"#
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }
}
